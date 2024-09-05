#!/usr/bin/env sh

set -e
# set -x

SCRIPT=$(realpath "$0")
SCRIPT_NAME=$(basename "$SCRIPT")
USAGE=$(cat <<EOF
$SCRIPT_NAME [-sS] -f file -r dir
$SCRIPT_NAME -r dir [-b] [-k extra_k2_args] -i index_name -l libraries

The first command line runs the script in batch mode; other arguments
can be provided but will be overridden by those in the file.

The options are as follows:
    -b  Run bracken on kraken indexes
    -f  Run script in batch mode reading arguments from <file>
    -h  Print this help message and exit
    -i  Give a name to the index
    -k  String of extra arguments to be passed to kraken2-build
    -l  A space delimited, quoted-string of libraries needed to build index
    -r  The root directory while index building will take place
    -s  Schedule index building jobs to be run by SLURM
    -S  Use SSH to parallelize index building jobs, requires host to be set in config file
EOF
)

# Determines the number of threads bracken uses.
if [ -z "$THREADS" ]; then
    if [ "$(uname)" = "Linux" ]; then
        THREADS=$(lscpu | awk '/^CPU\(s\)/ { print $2 }')
    else
        THREADS=$(sysctl hw.ncpu | awk '{ print $2 }')
    fi
fi
# Try to keep this at a reasonable number since it determines the
# number of sockets k2 will open when downloading files from NCBI.
K2_THREADS=6

# For each of the $K2_THREADS subprocesses that k2 spawns when processing
# the library files, each subprocess will spawn a masker with this
# number of threads.
MASKER_THREADS=4

NCBI_CXX_TOOLKIT="ftp://ftp.ncbi.nih.gov/toolbox/ncbi_tools++/CURRENT/ncbi_cxx--25_2_0.tar.gz"

mkdirs() {
    for dir in "$@"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
        fi
    done
}

install_binaries() {
    if [ ! -e "$ROOT/bin/.installed_binaries" ]; then
        touch "$ROOT/bin/.installed_binaries"
    fi
    kraken2_installed=$(get_task_status "$ROOT/bin/.installed_binaries" kraken2)
    maskers_installed=$(get_task_status "$ROOT/bin/.installed_binaries" maskers)
    bracken_installed=$(get_task_status "$ROOT/bin/.installed_binaries" bracken)
    ktaxonomy_installed=$(get_task_status "$ROOT/bin/.installed_binaries" ktaxonomy)
    db_report_installed=$(get_task_status "$ROOT/bin/.installed_binaries" db_report)
    if [ "$kraken2_installed" = "0" ]; then
        install_kraken2
    fi
    if [ "$bracken_installed" = "0" ]; then
        install_bracken
    fi
    if [ "$ktaxonomy_installed" = "0" ]; then
        install_ktaxonomy
    fi
    if [ "$db_report_installed" = "0" ]; then
        install_db_report
    fi
    if [ "$maskers_installed" = "0" ]; then
        install_maskers
    fi
}

install_ktaxonomy() {
    cd "$ROOT/tmp"
    if [ -e KrakenTools ]; then
        rm -rf KrakenTools
    fi
    git clone "https://github.com/jenniferlu717/KrakenTools" && cd KrakenTools
    cp make_ktaxonomy.py "$ROOT/bin"
    set_task_status "$ROOT/bin/.installed_binaries" "ktaxonomy" "1"
}

install_db_report() {
    cd "$ROOT/tmp"
    if [ -e k2-extra ]; then
        rm -rf k2-extra
    fi
    git clone "https://github.com/langmead-lab/k2-extra" && cd k2-extra
    cp generate_db_report.awk "$ROOT/bin"
    set_task_status "$ROOT/bin/.installed_binaries" "db_report" "1"
}


install_maskers() {
    cd "$ROOT/tmp"
    build_duskmasker=0
    build_segmasker=0
    # kraken2 ships with a masker
    # uncomment this if you prefer dustmasker
    # if [ ! -e "$ROOT/bin/dustmasker" ]; then
    #     build_duskmasker=1
    # fi

    # segmasker is used for masking proteins
    # uncomment this if you need segmasker installed
    # if [ ! -e "$ROOT/bin/segmasker" ]; then
    #     build_segmasker=1
    # fi
    if [ "$build_duskmasker" -eq 1 ] || [ "$build_segmasker" -eq 1 ]; then
        wget $NCBI_CXX_TOOLKIT && gunzip -c ncbi_cxx--25_2_0.tar.gz | tar xvf -
        cd ncbi_cxx--25_2_0
        ./configure --without-debug --with-optimization || exit 1
        oldpwd=$(pwd)
        cd ./*-Release*/build && gmake -j8 all_r || exit 1
        cd "$oldpwd" && cp ./*-Release*/bin/*masker "$ROOT/bin"
    fi
    set_task_status "$ROOT/bin/.installed_binaries" maskers 1
}

install_bracken() {
    cd "$ROOT/tmp"
    wget "https://github.com/jenniferlu717/Bracken/archive/v2.5.tar.gz"
    tar xzf v2.5.tar.gz && cd Bracken-2.5
    git clone "https://github.com/jenniferlu717/Bracken" && cd Bracken
    chmod +x bracken-build bracken && cp bracken-build bracken "$ROOT/bin"
    cd src && gmake && mv kmer2read_distr ./*.py "$ROOT/bin"
    set_task_status "$ROOT/bin/.installed_binaries" bracken 1
}

install_kraken2() {
    cd "$ROOT/tmp"
    # wget "https://github.com/DerrickWood/kraken2/archive/v2.1.2.tar.gz"
    # tar xzf v2.1.2.tar.gz && cd kraken2-2.1.2/src && make && make install KRAKEN2_DIR="$ROOT/bin"
    git clone "https://github.com/DerrickWood/kraken2" &&\
        cd "$ROOT/tmp/kraken2" && make &&\
        make install KRAKEN2_DIR="$ROOT/bin" &&\
        set_task_status "$ROOT/bin/.installed_binaries" kraken2 1
}

build_k2_index() {
    if [ -z "$*" ]; then
        k2 build --db "$PWD"
    else
        k2 build --db "$PWD" $@
    fi \
       && k2 inspect --db "$PWD" > inspect.txt || exit 1
}

make_ktaxonomy() {
    TAXONOMY="$ROOT/kraken2/taxonomy"
    make_ktaxonomy.py --nodes "$TAXONOMY/nodes.dmp" --names "$TAXONOMY/names.dmp" --seqid2taxid seqid2taxid.map -o ktaxonomy.tsv
}

run_bracken() {
    BRACKEN_THREADS=$((THREADS / 2))
    for read_length in 50 75 100 150 200 250 300; do
        bracken-build -d . -t ${BRACKEN_THREADS} -l $read_length
    done || exit 1
}

download_taxonomy() {
    cd "$ROOT/kraken2"
    status=$(get_task_status ".downloaded_taxonomy" "success")
    if [ "$status" != "1" ]; then
        k2 download-taxonomy --db .
    fi && set_task_status ".downloaded_taxonomy" "success" 1
}

download_libraries() {
    cd "$ROOT/kraken2"

    if [ ! -e ".downloaded_libraries" ]; then
        touch ".downloaded_libraries"
    fi

    for lib in $libraries; do
        status=$(get_task_status ".downloaded_libraries" "$lib")
        if [ "$status" = "1" ]; then
            continue
        fi
        nomask=""
        if [ "$lib" = "human_nomask" ]; then
            masker_args="--no-masking"
            lib="human"
        else
            masker_args="--masker-threads=${MASKER_THREADS}"
        fi

        k2 download-library --db . --library "$lib" --threads ${K2_THREADS} "$masker_args" --log "${lib}.log"
        k2 clean --db . --pattern "library/$lib/genomes" --log "${lib}.log"
        success=$?
        if [ -n "$nomask" ]; then
            mv "./library/$lib" "./library/${lib}_nomask"
            lib="${lib}_nomask"
        fi
        if [ "$success" = 0 ]; then
            set_task_status ".downloaded_libraries" "$lib" 1 $(date +"%Y%m%d")
        fi
    done
}

get_task_status() {
    filename="$1"
    entry=$2

    if [ -e "$filename" ] && grep -Fw "$entry" "$filename" > /dev/null; then
        status=$(grep -w "$entry" "$filename" | awk '{ print $2 }')
        echo "$status"
    else
        echo 0
    fi
}

set_task_status() {
    filename="$1"; shift
    entry=$1; shift
    new_status=$1; shift
    extra="$*"

    if [ -f "$filename" ] && grep -Fw "$entry" "$filename" > /dev/null; then
        old_status=$(get_task_status "$filename" "$entry")
        sed -i -e "/$entry/s/$old_status/$new_status/" "$filename"
    else
        printf "%s\t%s\t%s\n" "$entry" "$new_status" "$extra" >> "$filename"
    fi
}

reset_task_status() {
    filenames=$(find "$ROOT" -name ".*" -type f -print)
    for file in $filenames; do
        sed -i -e 's/1/0/' "$file"
    done

}

update_index_build_status() {
    index_name=$1
    if [ -z "$INDEX_RECIPES" ]; then
        return
    fi

    # change the 'completed' status of an index
    sed -i -e "/${index_name}\$/,/completed/s/completed: false/completed: true/" "$INDEX_RECIPES"
}

finalize_index() {
    index=$(basename "$(pwd)")
    filenames="hash.k2d opts.k2d taxo.k2d seqid2taxid.map inspect.txt ktaxonomy.tsv library_report.tsv"
    if [ -n "$run_bracken" ]; then
        kmer_distrib_files=$(find . -type f -name  "*.kmer_distrib" -print | tr '\n' ' ')
        filenames="$filenames $kmer_distrib_files"
    fi
    if [ -e "unmapped_accessions.txt" ]; then
       filenames="$filenames unmapped_accessions.txt"
    fi
    awk -f "$ROOT/bin/generate_db_report.awk" -F'\t' prelim_map.txt > library_report.tsv
    mkdirs "$ROOT/dbs/$index"
    old_archives=$(find "$ROOT/dbs/$index/" -type f -name "*.tar.gz")
    if [ -n "$old_archives" ]; then
        for archive in $old_archives; do
            mv "$archive" "$ROOT/dbs/archive"
        done
    fi
    for file in "$ROOT/dbs/$index/"*; do
        rm -f "$file"
    done
    for file in $filenames ; do
        if [ -e "$file" ]; then
            mv "$file" "$ROOT/dbs/$index"
        fi
    done
    build_date=$(sort "$ROOT/kraken2/.downloaded_libraries" | head -1 | awk '{ print $3 }')
    if [ -z "$build_date" ]; then
        build_date=$(date +"%Y%m%d")
    fi

    cd "$ROOT/dbs/$index" && \
        md5sum -- $filenames > "${index}.md5" && \
        tar czf "k2_${index}_${build_date}.tar.gz" $filenames && \
        md5sum --  *.tar.gz >> "${index}.md5" && \
        update_index_build_status "$index"
}

string_sort() {
    echo "$1" | tr ' ' '\n' | sort | tr '\n' ' '
}

make_index() {
    if [ $# -lt 2 ]; then
        echo "Error: make_index 'index_name' 'lib [lib ...]'"
        exit 1
    fi
    if [ $# -gt 4 ]; then
        echo "make_index expects at most 4 arguments, at $# given."
    fi

    for i in $(seq 1 $#); do
        case $i in
            1) index_name=$1; shift ;;
            2) libraries=$1; shift ;;
            3) extra_k2_args=$1; shift ;;
            4) run_bracken=$1; shift ;;
        esac
    done

    cd "$ROOT/kraken2"
    libraries=$(string_sort "$libraries")

    if [ -d "$index_name" ]; then
        cd "$index_name"
        existing_libraries=$(ls library)
        existing_libraries=$(string_sort "$existing_libraries")

        if [ "$existing_libraries" != "$libraries" ]; then
            rm -rf -- *
        fi
    else
        mkdirs "$index_name" && cd "$index_name"
    fi

    ln -fs "$ROOT/kraken2/taxonomy" .
    mkdirs library && cd library
    for lib in $libraries; do
        ln -fs "$ROOT/kraken2/library/$lib" .
    done && cd "$ROOT/kraken2/$index_name"
    if [ "$extra_k2_args" = "none" ]; then
        extra_k2_args=""
    fi
    if [ "$run_bracken" = "true" ]; then
        build_k2_index "$extra_k2_args" && make_ktaxonomy && \
            run_bracken && finalize_index \
            && cd "$ROOT/kraken2" && rm -rf "$index_name"
    else
        build_k2_index "$extra_k2_args" && make_ktaxonomy && \
            finalize_index && cd "$ROOT/kraken2" && rm -rf "$index_name"
    fi
}

get_libraries_from_file() {
    filename="$1"
    libraries=""

    awk '
        BEGIN { added = 0 }

        /^#/ { next }

        /libraries/ {
            lib_count = 0
            for (i = 2; i <= NF; i++) {
                lib_count += 1
                libraries[lib_count] = $i
            }
        }

        /completed.*false/ {
            for (i = 1; i <= lib_count; i++) {
                if (libraries[i] in output)
                   continue
                output[libraries[i]] = 1
            }
        }

        END {
            for (lib in output)
                printf "%s ", lib
        }
' "$filename"
}

build_over_ssh() {
    index_name=$1
    libraries=$2
    extra_k2_args=$3
    run_bracken=$4
    host=$5

    if [ "$run_bracken" = "true" ]; then
        bracken_arg="-b"
    fi

    ssh -n "$host" -- "which tmux > /dev/null"
    if [ $? -eq 0 ]; then
        has_session=$(ssh -n "$host" -- "tmux has-session -t kraken2 2> /dev/null")
        if [ "$has_session" = "0" ]; then
            ssh -n "$host" -- tmux new-session -s kraken2 -d
        else
            ssh -n "$host" -- tmux new-window -t kraken2
        fi

        window_index=$(ssh -n "$host" -- tmux list-windows | grep -F active | cut -d: -f1 )
        ssh -n "$host" -- tmux rename-window -t "kraken2:${window_index}" "$index_name"
        ssh -n "$host" -- tmux send-keys -t "kraken2:${index_name}" "\"export INDEX_RECIPES=${INDEX_RECIPES}; sh $SCRIPT -i '$index_name' -l '$libraries' -k '$extra_k2_args' -r '$ROOT' $bracken_arg && exit 0\"" ENTER

        return
    fi

    ssh -n "$host" "which screen > /dev/null"
    if [ $? -eq 0 ]; then
        has_session=$(ssh -n "$host" -- "screen -ls 2> | grep -F ${index_name}")
        if [ "$has_session" = "0" ]; then
            ssh -n "$host" -- screen -S kraken2 -X screen -t "$index_name"
        else
            ssh -n "$host" -- screen -S kraken2 -d m
            ssh -n "$host" -- screen -S kraken -p0 title "$index_name"
        fi

        ssh -n "$host" -- screen -S kraken2 -p "$index_name" -X stuff "export INDEX_RECIPES=${INDEX_RECIPES}; sh $SCRIPT -i '$index_name' -l '$libraries' -k '$extra_k2_args' -r '$ROOT' $bracken_arg && exit 0\015"
    fi
}

build_indexes_from_file() {
    filename="$1"
    use_slurm=$2
    export INDEX_RECIPES="$(realpath $filename)"
    OLDIFS=$IFS
    IFS="	"
    awk '
        BEGIN { RS = ""; FS = "\n" }
        /completed: false/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^#/)
                           continue
                        split($i, a, ":[[:space:]]")
                        val[a[1]] = a[2]
                    }
                    if ("host" in val) {
                        printf("%s\t%s\t%s\t%s\t%s\n",
                               val["name"],
                               val["libraries"],
                               val["extra_k2_args"],
                               val["run_bracken"],
                               val["host"])

                    } else {
                        printf("%s\t%s\t%s\t%s\n",
                               val["name"],
                               val["libraries"],
                               val["extra_k2_args"],
                               val["run_bracken"])
                    }
                    for (v in val)
                        delete val[i]
        }
' "$filename" | while read -r index_name libraries extra_k2_args run_bracken host; do
        if [ "$use_slurm" = 1 ]; then
            if [ "$run_bracken" = "true" ]; then
                bracken_arg="-b"
            fi
            cat <<EOF | sed -e 's/^[[:space:]]*//' | sbatch
                 #!/bin/sh
                 #SBATCH --partition=workers
                 #SBATCH --nodes=1
                 #SBATCH --job-name=building_${index_name}
                 export INDEX_RECIPES=$INDEX_RECIPES
                 export K2_SLURM_JOB=1
                 IFS=$OLDIFS
                 sh $SCRIPT -i '$index_name' -l '$libraries' -k '$extra_k2_args' -r '$ROOT' $bracken_arg
EOF
        elif [ "$use_ssh" = 1 ]; then
            IFS=" "
            build_over_ssh "$index_name" "$libraries" "$extra_k2_args" "$run_bracken" "$host"
            IFS="	"
        else
            IFS=" "
            make_index "$index_name" "$libraries" "$extra_k2_args" "$run_bracken"
            IFS="	"

        fi
    done

    IFS="$OLDIFS"
}

setup_dependencies() {
    mkdirs "$ROOT/bin" "$ROOT/dbs" "$ROOT/kraken2" "$ROOT/tmp" && \
    install_binaries && \
    download_taxonomy && \
    download_libraries "$1"
}

print_usage() {
    printf "%s\n" "$USAGE"
}

[ $# -eq 0 ] && print_usage && exit

while getopts "bf:hi:k:l:r:sS" opt; do
    case $opt in
        b) use_bracken="true" ;;
        f) batch_filename=$(realpath "$OPTARG") ;;
        i) index_name="$OPTARG" ;;
        l) libraries="$OPTARG" ;;
        k) extra_k2_args="$OPTARG" ;;
        r) ROOT="$OPTARG" ;;
        s) use_slurm=1 ;;
        S) use_ssh=1 ;;
        h) print_usage && exit 1 ;;
        ?) print_usage && exit 1 ;;
    esac
done

shift $((OPTIND - 1))

if [ -n "$*" ]; then
     echo "Unknown positional argument(s): " "$@"
     print_usage && exit 1
fi

export PATH="$ROOT/bin:$PATH"
if [ -z "$K2_SLURM_JOB" ]; then
    if [ -n "$batch_filename" ]; then
        libraries=$(get_libraries_from_file "$batch_filename")
    fi
    setup_dependencies "$libraries"
fi
if [ -n "$batch_filename" ]; then
    build_indexes_from_file "$batch_filename" "$use_slurm"
else
    make_index "$index_name" "$libraries" "$extra_k2_args" "$use_bracken"
fi
