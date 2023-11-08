# Introduction

This repository contains the scripts that we use to build the
[Kraken 2 indexes](https://benlangmead.github.io/aws-indexes/k2 "Kraken2 indexes")
hosted on AWS.

The `build_k2_indexes.sh` script accepts the following options:
```
    -b  Run bracken on kraken indexes
    -f  Run script in batch mode reading arguments from <file>
    -h  Print this help message and exit
    -i  Give a name to the index
    -k  String of extra arguments to be passed to kraken2-build
    -l  A space delimited string of libraries needed to build index
    -s  Schedule index building jobs to be run by SLURM
```

Arguments containing spaces should be enclosed in double-quotes before being passed.

Upon first invocation, `build_k2_indexes.sh` will create the required directory structure
and install all the necessary binaries and scripts to their intended locations.
The `taxonomy` database will also be download and unpacked in `$ROOT/kraken2/taxonomy`

# Batch Mode
The script also supports a batch mode where the parameters for
building an index are specified in a simple `key: value` type config file.
A sample configuration file is given below:

```text
name: viral
libraries: viral
extra_k2_args: none
run_bracken: true
completed: true

name: microbial
libraries: archaea bacteria fungi protozoa viral UniVec_Core
extra_k2_args: none
run_bracken: true
completed: true

name: minusb
libraries: archaea viral plasmid human_nomask UniVec_Core
extra_k2_args: none
run_bracken: true
completed: true

name: standard08gb
libraries: archaea bacteria viral plasmid human_nomask UniVec_Core
extra_k2_args: --max-db-size 8000000000
run_bracken: true
completed: true
```

In batch mode, `build_k2_indexes.sh` can also utilize SLURM to build indexes across
available nodes in a cluster.

**N.B.** -- the `#SBATCH` parameters contained in the script may need to edited to match
your cluster's configuration.

# Examples
The command below will build a index called `microbial` that depends on
these libraries:
* archaea
* bacteria
* fungi
* protozoa
* viral
* UniVec_Core

```shell
./build_k2_indexes.sh -i microbial -l "archaea bacteria fungi protozoa viral UniVec_Core"
```

This command will kick off the following events:

* a directory called `microbial` will be created under the `kraken2` directory
* libraries that have yet to be downloaded will be retrieved
* the required libraries will be symlinked into `kraken2/microbial`
* the `taxonomy` directory will be symlinked into `kraken2/microbial`
* the required `kraken2` binaries will be invoked to fascilitate the build
* any additional scripts for generating meta-data files will be called
* the requried files are moved to `dbs/microbial` where they are archived
* an MD5 sum is generated for all files in this directory

# Directory Structure
The `$ROOT` directory contains the following subdirectories:
```
+-----------+-------------------------------------------------------------------+
| Directory | Description                                                       |
|:----------|:------------------------------------------------------------------|
| bin       | contains the binaries and scripts needed by `build_k2_indexes.sh` |
| dbs       | the directory that the finalized index will be moved to           |
| kraken2   | the staging directory where indexes and other files are built     |
| tmp       | the directory where binaries are built before being moved to bin  |
+-----------+-------------------------------------------------------------------+
```

# FAQ
### Why are my libraries not being updated?

>Make sure to reset the status of the tasks in `$ROOT/kraken2/.downloaded_libraries`

### Why does the script return without doing anything when using batch mode?

>Make sure to re-set the `completed` status to `false` in your batch file.

### Why do my SLURM jobs keep failing?

>Make sure that the `SBATCH` parameters hard coded in the script match your server's config.
If the jobs are being terminated prematurely, make sure that they are being submitted to a
partition with a `TIMELIMIT` greater than the job's runtime.

### Why is segmasker/dustmasker not getting installed?

>Uncomment the code in the `install_maskers` function. Kraken2 ships with a nucleotide
masker; segmasker is required for building protein databases

### What is build_db_report.awk?

>This is the script that generates the `library_report.tsv` that ships with every
index. The script uses metadata from a *modified* version of `prelim_map.txt` file
to create a final report of all the sequence (names) that make up an index, the
library that the sequence is part of, an the URL from where is was downloaded.
This report can only be generated if the index is built with the
[k2 script](https://github.com/DerrickWood/kraken2/blob/master/scripts/k2).

### Can this script be used with the original Kraken 2 scripts?

> Yes! Search for `# original` in the script and uncomment/comment as needed.
`library_report.tsv` will need to be removed from the `filenames` variable
inside `finalize_index`. See above for details.

# See Also
* [Bracken](https://github.com/jenniferlu717/Bracken)
* [Kraken2](https://github.com/DerrickWood/kraken2)
* [KrakenTools](https://github.com/jenniferlu717/KrakenTools)
