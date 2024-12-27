BEGIN {
    NCBI_SERVER = "ftp.ncbi.nlm.nih.gov"
    print "#Library\tSequence Name\tURL"
    library = ""
}

/^#/ {
    split($0, fields, " ")
    library = fields[4]
    next
}

{
    sub(/kraken:taxid\|[0-9]+\|/, "", $2)
    name = $2 " " $4
    url = $5
    if ($1 ~ /TAXID/) {
        records[$2] = library"\t"name"\t"url
    } else {
        records[$3] = library"\t"name"\t"url
    }
}

END {
    while (getline seqname < "unmapped_accessions.txt" > 0) {
        delete records[seqname]
    }

    for (record in records) print records[record]
}
