#!/usr/bin/env sh

set -e
# set -x

SCRIPT_PATH=$(realpath "$0")
SCRIPT_NAME=$(basename "$0")
USAGE=$(cat <<EOF
build_k2_indexes.sh [ -s <slurm_args> | -S <ssh_args> ] [-d] -f file -r <dir>
build_k2_indexes.sh -r <dir> [-bd] [-k extra_k2_args] -i index_name -l libraries

The first command line runs the script in batch mode; other arguments
can be provided but will be overridden by those in the file.

The options are as follows:
    -b  Run bracken on resulting indexes
    -d  Download all prerequisites needed for building indexes
    -f  Run script in batch mode reading arguments from <file>
    -h  Print this help message and exit
    -i  Give a name to the index
    -k  String of extra arguments to be passed to kraken2-build
    -l  A space delimited, quoted-string of libraries needed to build index
    -r  The root directory while index building will take place
    -s  SLURM arguments that will be passed to sbatch command
    -S  The destination, specified as user@host or host, that ssh will connect to
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
    k2_extra_installed=$(get_task_status "$ROOT/bin/.installed_binaries" k2_extra)

    if [ "$kraken2_installed" = "0" ]; then
        install_kraken2
    fi
    if [ "$bracken_installed" = "0" ]; then
        install_bracken
    fi
    if [ "$ktaxonomy_installed" = "0" ]; then
        install_ktaxonomy
    fi
    if [ "$maskers_installed" = "0" ]; then
        install_maskers
    fi
    if [ "$k2_extra_installed" = "0" ]; then
        install_k2_extra
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

install_k2_extra() {
    cd "$ROOT/tmp"
    if [ -d k2-extra ]; then
        rm -rf k2-extra
    fi
    git clone "https://github.com/langmead-lab/k2-extra" && cd k2-extra
    chmod +x build_k2_indexes.sh generate_db_report.awk
    cp build_k2_indexes.sh generate_db_report.awk "$ROOT/bin"
    set_task_status "$ROOT/bin/.installed_binaries" "k2_extra" "1"
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
    if [ -d "Bracken" ]; then
        rm -rf Bracken
    fi
    # wget "https://github.com/jenniferlu717/Bracken/archive/v2.5.tar.gz"
    # tar xzf v2.5.tar.gz && cd Bracken-2.5
    git clone "https://github.com/jenniferlu717/Bracken" && cd Bracken
    chmod +x bracken-build bracken && cp bracken-build bracken "$ROOT/bin"
    cd src && gmake && mv kmer2read_distr ./*.py "$ROOT/bin"
    set_task_status "$ROOT/bin/.installed_binaries" bracken 1
}

install_kraken2() {
    cd "$ROOT/tmp"
    if [ -d "kraken2" ]; then
        rm -rf kraken2
    fi
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
       && k2 inspect --db "$PWD" --output inspect.txt || exit 1
}

make_ktaxonomy() {
    TAXONOMY="$ROOT/kraken2/taxonomy"
    make_ktaxonomy.py --nodes "$TAXONOMY/nodes.dmp" --names "$TAXONOMY/names.dmp" --seqid2taxid seqid2taxid.map -o ktaxonomy.tsv
}

run_bracken() {
    for read_length in 50 75 100 150 200 250 300; do
        bracken-build -d . -t "${THREADS}" -l "$read_length"
    done
}

download_taxonomy() {
    cd "$ROOT/kraken2"
    status=$(get_task_status ".downloaded_taxonomy" "success")
    if [ "$status" != "1" ]; then
        k2 download-taxonomy --db .
    fi && set_task_status ".downloaded_taxonomy" "success" 1
}

is_downloaded_library() {
    library=$(echo "$1" | sed -E -ne 's/(_nomask$|$)//p')
    case "$library" in
        human | viral | plasmid | protozoa | archaea | fungi | bacteria | plant | UniVec | UniVec_Core) echo 0 ;;
        *) echo 1 ;;
    esac
}

download_libraries() {
    libs="$1"
    cd "$ROOT/kraken2"

    if [ ! -e ".downloaded_libraries" ]; then
        touch ".downloaded_libraries"
    fi

    set -o noglob
    for lib in $libs; do
        if [ "$lib" = "none" ] || [ -z "$lib" ]; then
            continue
        fi

        status=$(get_task_status ".downloaded_libraries" "$lib")
        if [ "$status" = "1" ]; then
            continue
        fi

        # TODO: change this
        if [ "$lib" = "human_nomask" ]; then
            masker_args="--no-masking"
            lib="human"
        else
            masker_args="--masker-threads=${MASKER_THREADS}"
        fi

        # downloaded=$(is_downloaded_library "$lib")
        if [ -f "$lib" ] || echo "$lib" | grep '[/*?]'; then
            added="true"
        fi

        if [ "$added" = "true" ]; then
            k2 add-to-library --db . --file "$lib" --threads ${K2_THREADS}
        else
            k2 download-library --db . --library "$lib" --threads ${K2_THREADS} "$masker_args" --log "${lib}.log"
            k2 clean --db . --pattern "library/$lib/genomes" --log "${lib}.log"

            success=$?
            if [ "$masker_args" = "--no-masking" ]; then
                mv "./library/$lib" "./library/${lib}_nomask"
                lib="${lib}_nomask"
            fi

            if [ "$success" = 0 ]; then
                set_task_status ".downloaded_libraries" "$lib" 1 $(date +"%Y%m%d")
            fi
        fi
    done
    set +o noglob
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
    if [ -z "$INDEX_RECIPES" ] || [ ! -e "$INDEX_RECIPES" ]; then
        return
    fi

    # change the 'completed' status of an index
    sed -i -e "/${index_name}\$/,/completed/s/completed: false/completed: true/" "$INDEX_RECIPES"
}

finalize_index() {
    index=$(basename "$(pwd)")
    cp "$ROOT/kraken2/taxonomy/names.dmp" "$PWD"
    cp "$ROOT/kraken2/taxonomy/nodes.dmp" "$PWD"
    filenames="hash.k2d opts.k2d taxo.k2d seqid2taxid.map inspect.txt ktaxonomy.tsv library_report.tsv"
    filenames="$filenames nodes.dmp names.dmp"
    if [ -n "$run_bracken" ]; then
        filenames="$filenames database50mers.kmer_distrib database75mers.kmer_distrib database100mers.kmer_distrib database150mers.kmer_distrib database200mers.kmer_distrib database250mers.kmer_distrib database300mers.kmer_distrib"
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
        echo "make_index expects at most 4 arguments, $# given."
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

    # if [ -d "$index_name" ]; then
    #     cd "$index_name"
    #     existing_libraries=$(ls library)
    #     existing_libraries=$(string_sort "$existing_libraries")

    #     if [ "$existing_libraries" != "$libraries" ]; then
    #         rm -rf -- *
    #     fi
    # else
    # fi
    mkdirs "$index_name" && cd "$index_name"

    # Special databases such as GTDB and Greengenes come
    # with the own taxonomy files. Do not try to create a
    # symlink in such circumstances.
    if [ ! -d "taxonomy" ]; then
        ln -fs "$ROOT/kraken2/taxonomy" .
    fi
    mkdirs library && cd library

    for lib in $libraries; do
        if [ "$lib" != "none" ]; then
            continue
        fi
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
            print_space = 0
            for (lib in output) {
                if (print_space == 1)
                   printf " "
                printf "%s", lib
                print_space = 1
            }
        }
' "$filename"
}

build_using_slurm() {
    index_name=$1
    libraries=$2
    extra_k2_args=$3
    run_bracken=$4
    slurm_args=$5

    if [ "$run_bracken" = "true" ]; then
        bracken_arg="-b"
    else
        bracken_arg=
    fi

    index_recipes=
    sbcast_command=
    if [ -n "$batch_filename" ]; then
        basename=$(basename "$batch_filename")
        index_recipes="$ROOT/$basename"
        sbcast_command="sbcast $index_recipes '$ROOT'; sbcast $batch_filename '$ROOT'"
    fi

    cat <<EOF | sed -e 's/^[[:space:]]*//' | sbatch
        #!/bin/sh
        #SBATCH $slurm_args
        export K2_SLURM_JOB=1
        IFS=$OLDIFS
        export INDEX_RECIPES=$index_recipes
        $sbcast_command
        sh $ROOT/$SCRIPT -i '$index_name' -l '$libraries' -k '$extra_k2_args' -r '$ROOT' $bracken_arg
EOF

}
build_over_ssh() {
    index_name=$1
    libraries=$2
    extra_k2_args=$3
    run_bracken=$4
    host=$5

    if [ "$run_bracken" = "true" ]; then
        bracken_arg="-b"
    else
        bracken_arg=
    fi

    index_recipes=
    sbcast_command=
    if [ -n "$batch_filename" ]; then
        basename=$(basename "$batch_filename")
        INDEX_RECIPES="$ROOT/$basename"
        ssh -n "$host" "mkdir -p '$ROOT'"
        scp "$batch_filename" "$host:$ROOT"
        scp "$SCRIPT_PATH" "$host:$ROOT"

    fi

    command="export INDEX_RECIPES='$INDEX_RECIPES'; sh $ROOT/$SCRIPT_NAME -i '$index_name' -l '$libraries' -k '$extra_k2_args' ${bracken_arg} -r '$ROOT'"

    has_tmux=$(ssh -n "$host" -- "which tmux 2>&1 > /dev/null; echo $?")
    if [ "$has_tmux" = "0" ]; then
        has_session=$(ssh -n "$host" -- "tmux has-session -t kraken2 2>&1 > /dev/null; echo $?")
        if [ "$has_session" = "0" ]; then
            ssh -n "$host" -- tmux new-window -t kraken2
        else
            ssh -n "$host" -- tmux new-session -s kraken2 -d
        fi

        window_index=$(ssh -n "$host" -- "tmux list-windows | grep -F active | cut -d: -f1" )
        ssh -n "$host" -- tmux rename-window -t "kraken2:${window_index}" "$index_name"
        ssh -n "$host" -- tmux send-keys -t "kraken2:${index_name}" "\"$command\"" ENTER

        return
    fi

    has_screen=$(ssh -n "$host" "which screen 2>&1 > /dev/null; echo $?")
    if [ "$has_screen" = "0" ]; then
        has_session=$(ssh -n "$host" -- "screen -ls 2>&1 | grep -F kraken2" || echo "not found")
        if [ "$has_session" != "not found" ]; then
            ssh -n "$host" -- screen -r kraken2 -X screen -t "$index_name"
        else
            ssh -n "$host" -- screen -S kraken2 -d -m
            ssh -n "$host" -- screen -r kraken2 -p0 -X title "$index_name"
        fi

        ssh -n "$host" -- screen -r kraken2 -p "$index_name" -X stuff "\"$command\""

        return
    fi

    if [ -x nohup ]; then
        ssh -n "host" -- nohup "$command"
        return
    fi

    echo "Could not find tmux, screen or nohup on " $( echo "${host}" | cut -d '@' -f2 ) " ..exiting"
    exit 1

}

build_indexes_from_file() {
    filename="$1"
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
                    if ("ssh_args" in val && val["ssh_args"] != "none") {
                        printf("%s\t%s\t%s\t%s\t%s\t%s\n",
                               val["name"],
                               val["libraries"],
                               val["extra_k2_args"],
                               val["run_bracken"],
                               "ssh",
                               val["ssh_args"])

                    } else if ("slurm_args" in val && val["slurm_args"] != "none"){
                        printf("%s\t%s\t%s\t%s\t%s\t%s\n",
                               val["name"],
                               val["libraries"],
                               val["extra_k2_args"],
                               val["run_bracken"],
                               "slurm",
                               val["slurm_args"])

                    } else {
                        printf("%s\t%s\t%s\t%s\t%s\t%s\n",
                               val["name"],
                               val["libraries"],
                               val["extra_k2_args"],
                               val["run_bracken"],
                               "none",
                               "none")
                    }
                    for (v in val)
                        delete val[i]
        }
' "$filename" | while read -r index_name libs extra_k2_args run_bracken sched_type sched_args; do
        # remove filepaths in list of libraries; they should exist in added directory
        set -o noglob
        libraries=""
        IFS=$OLDIFS
        for library in $libs; do
            # downloaded=$(is_downloaded_library "$library")
            if [ -f "$library" ] || echo "$library" | grep '[/*?]'; then
                added="true"
            else
                libraries="$libraries $library"
            fi
        done
        if [ "$added" = "true" ]; then
            libraries="$libraries added"
        fi
        set +o noglob
        IFS="	"

        if [ "$sched_type" = "slurm" ]; then
            build_using_slurm "$index_name" "$libraries" "$extra_k2_args" "$run_bracken" "$sched_args"
        elif [ "$sched_type" = "ssh" ]; then
            echo "$sched_args"
            IFS=" "
            build_over_ssh "$index_name" "$libraries" "$extra_k2_args" "$run_bracken" "$sched_args"
            IFS="	"
        else
            IFS=" "
            setup_dependencies "$libs"
            make_index "$index_name" "$libraries" "$extra_k2_args" "$run_bracken"
            IFS="	"

        fi
    done

    IFS="$OLDIFS"
}

setup_dependencies() {
    mkdirs "$ROOT/bin" "$ROOT/dbs" "$ROOT/kraken2" "$ROOT/tmp" && \
    install_binaries
    if [ "$1" != "none" ]; then
        download_taxonomy
        download_libraries "$1"
    fi
}

print_usage() {
    printf "%s\n" "$USAGE"
}

clean_up() {
    if [ -f "$ROOT/.lock" ]; then
        rm -f "$ROOT/.lock"
    fi
}

trap clean_up EXIT
trap clean_up INT
trap clean_up QUIT

[ $# -eq 0 ] && print_usage && exit

while getopts "bf:hi:k:l:r:s:S:" opt; do
    case $opt in
        b) run_bracken="true" ;;
        f) batch_filename=$(realpath "$OPTARG") ;;
        i) index_name="$OPTARG" ;;
        l) libraries="$OPTARG" ;;
        k) extra_k2_args="$OPTARG" ;;
        r) ROOT="$OPTARG" ;;
        s) slurm_args="$OPTARG" ;;
        S) ssh_args="$OPTARG" ;;
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

if [ -n "$batch_filename" ]; then
    libraries=$(get_libraries_from_file "$batch_filename")
    build_indexes_from_file "$batch_filename"
else
    if [ -n "$slurm_args" ] && [ "$slurm_args" != "none" ]; then
        build_using_slurm "$index_name" "$libraries" "$extra_k2_args" "$run_bracken" "$slurm_args"
    elif [ -n "$ssh_args" ] && [ "$ssh_args" != "none" ]; then
        build_over_ssh "$index_name" "$libraries" "$extra_k2_args" "$run_bracken" "$ssh_args"
    else
        if [ -e "$ROOT/.dep_lock" ]; then
            while [ -f "$ROOT/.dep_lock" ]; do
                sleep 1
            done
        else
            touch "$ROOT/.dep_lock"
            if [ -n "$INDEX_RECIPES" ]; then
                all_libraries=$(get_libraries_from_file "$INDEX_RECIPES")
                setup_dependencies "$all_libraries"
            else
                setup_dependencies "$libraries"
            fi
            rm "$ROOT/.dep_lock"
        fi
        make_index "$index_name" "$libraries" "$extra_k2_args" "$run_bracken"
    fi
fi
