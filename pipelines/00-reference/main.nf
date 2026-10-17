#!/usr/bin/env nextflow
/*
 * COG B-ALL / MD-ALL — step 0: reference bundle (run once per site)
 *
 * Builds the exact reference MD-ALL's 1,821-sample cohort was counted against:
 *   genome  GRCh38 no-alt analysis set + hs38d1 (NCBI GCA_000001405.15, UCSC names)
 *   genes   Ensembl release 102, chr1-22/X/Y/MT only, renamed chr* / chrM (60,616 genes)
 *   index   STAR 2.7.11b, --sjdbOverhang 100
 * Both downloads are checked against pinned SHA-256 sums.
 *
 *   nextflow run pipelines/00-reference -profile singularity --outdir /refs/cog-ball
 */
nextflow.enable.dsl = 2

params.genome_url    = 'https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna.gz'
params.genome_sha256 = '08959902840a28f410ad1220e36b2a3fbe2cb90beecceb6ea5b050a0e68ed96d'
params.gtf_url       = 'https://ftp.ensembl.org/pub/release-102/gtf/homo_sapiens/Homo_sapiens.GRCh38.102.gtf.gz'
params.gtf_sha256    = '307038294611aaf86c3e61e70273a26c7b3a343cd416feed137e6e86d471ea32'
params.sjdb_overhang = 100   // fixed in cog_star_index.sh; recorded in the manifest
// Suffix-array sparsity. 1 = ~32 GB RAM to build and map (COG default); 2 = ~20 GB, slower
// mapping. Keep 1 unless memory forces otherwise; the value is recorded in the manifest.
params.sa_sparse     = 1
params.save_fasta    = false

process VERIFY_DOWNLOAD {
    tag "${name}"
    label 'counts'
    cpus 1
    memory '1.GB'

    input:
    tuple val(name), path(archive), val(expected)

    output:
    tuple val(name), path(archive)

    script:
    """
    echo "${expected}  ${archive}" | sha256sum -c -
    """
}

process PREPARE_GENOME {
    label 'counts'
    cpus 4
    memory '4.GB'
    publishDir "${params.outdir}", mode: 'copy', enabled: params.save_fasta, pattern: '*.fa'

    input:
    path genome_gz

    output:
    path 'GRCh38_analysis_set.fa', emit: fasta
    path 'genome_headers.txt',     emit: headers

    script:
    """
    pigz -dc -p ${task.cpus} ${genome_gz} > GRCh38_analysis_set.fa
    grep '^>' GRCh38_analysis_set.fa > genome_headers.txt
    """
}

process PREPARE_GTF {
    label 'counts'
    cpus 1
    memory '2.GB'
    publishDir "${params.outdir}", mode: 'copy'

    input:
    path gtf_gz
    path headers

    output:
    path 'genes.gtf', emit: gtf
    path 'genes.gtf.log'

    script:
    """
    prepare_gtf.py --gtf ${gtf_gz} --fasta-headers ${headers} --out genes.gtf | tee genes.gtf.log
    """
}

process STAR_INDEX {
    label 'counts'
    cpus 8
    memory { params.sa_sparse > 1 ? 24.GB : 40.GB }
    time '8.h'
    publishDir "${params.outdir}", mode: 'copy'

    input:
    path fasta
    path gtf

    output:
    path 'star_index', emit: index

    script:
    def ram = (task.memory.toBytes() * 0.9) as long
    """
    cog_star_index.sh ${fasta} ${gtf} star_index ${task.cpus} ${params.sa_sparse} ${ram}
    """
}

process COLLAPSE_GTF {
    label 'counts'
    cpus 1
    memory '8.GB'
    publishDir "${params.outdir}", mode: 'copy'

    input:
    path gtf

    output:
    path 'genes.collapsed.gtf', emit: gtf

    script:
    // One transcript per gene, overlaps removed: the annotation RNA-SeQC (QC) needs.
    // Never used for counting.
    """
    collapse_annotation.py ${gtf} genes.collapsed.gtf
    """
}

process MANIFEST {
    label 'counts'
    cpus 1
    memory '1.GB'
    publishDir "${params.outdir}", mode: 'copy'

    input:
    path gtf
    path index
    path collapsed

    output:
    path 'reference_manifest.json'

    script:
    """
    make_reference_manifest.py --bundle . \
        --genome-url '${params.genome_url}' --genome-sha256 ${params.genome_sha256} \
        --gtf-url '${params.gtf_url}' --gtf-sha256 ${params.gtf_sha256} \
        --sjdb-overhang ${params.sjdb_overhang} --sa-sparse ${params.sa_sparse}
    """
}

workflow {
    if (!params.outdir) error "Set --outdir (where the reference bundle is written)"

    downloads = channel.of(
        ['genome', file(params.genome_url), params.genome_sha256],
        ['gtf',    file(params.gtf_url),    params.gtf_sha256]
    )
    verified = VERIFY_DOWNLOAD(downloads)
    genome_gz = verified.filter { name, _f -> name == 'genome' }.map { _name, f -> f }
    gtf_gz    = verified.filter { name, _f -> name == 'gtf' }.map { _name, f -> f }

    PREPARE_GENOME(genome_gz)
    PREPARE_GTF(gtf_gz, PREPARE_GENOME.out.headers)
    STAR_INDEX(PREPARE_GENOME.out.fasta, PREPARE_GTF.out.gtf)
    COLLAPSE_GTF(PREPARE_GTF.out.gtf)
    MANIFEST(PREPARE_GTF.out.gtf, STAR_INDEX.out.index, COLLAPSE_GTF.out.gtf)
}
