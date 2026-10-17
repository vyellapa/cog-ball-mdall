#!/usr/bin/env nextflow
/*
 * COG B-ALL / MD-ALL — step 1: FASTQ -> gene counts
 *
 * Reproduces the counting MD-ALL's reference cohort was built with
 * (gu-lab20/RNAseq): STAR two-pass -> samtools sort -> htseq-count
 * (-m intersection-strict -s no -a 10) -> MD-ALL DUX4 patch.
 *
 *   nextflow run pipelines/01-counts -profile singularity \
 *       --input samplesheet.csv --center CHOP --refs /refs/cog-ball --outdir /data/cog-ball-results
 *
 * samplesheet.csv:  sample,fastq_1,fastq_2      (fastq_2 empty for single-end;
 *                   repeat a sample on several rows for multiple lanes)
 *
 * Output: <outdir>/<center>/<sample>/counts/
 *           <sample>.htseq.dux4patched.tsv   input to 02-classify
 *           <sample>.htseq.tsv               raw htseq-count output
 *           <sample>.star.Log.final.out
 *           <sample>.rnaseqc.metrics.tsv     RNA-SeQC 2 QC metrics
 *           <sample>.genebody.tsv            5'->3' gene-body coverage profile
 *           <sample>.counts_qc.json          STAR + HTSeq + RNA-SeQC + coverage summary
 */
nextflow.enable.dsl = 2

params.input          = null
params.refs           = null     // output directory of 00-reference (default: REFS in site.conf)
params.save_bam       = false
params.save_chimeric  = false    // STAR Chimeric.out.junction (useful for fusion calling later)
params.min_unique_pct = 50
params.min_assigned   = 5000000

process STAR_ALIGN {
    tag "${sample}"
    label 'counts'
    cpus 8
    memory 40.GB
    time '12.h'
    publishDir "${params.outdir}/${params.center}/${sample}/counts", mode: 'copy',
        saveAs: { f -> f.endsWith('Log.final.out') ? "${sample}.star.Log.final.out" : null }
    publishDir "${params.outdir}/${params.center}/${sample}/bam", mode: 'copy', enabled: params.save_bam,
        pattern: "${sample}.bam*"
    publishDir "${params.outdir}/${params.center}/${sample}/star", mode: 'copy', enabled: params.save_chimeric,
        pattern: "${sample}.Chimeric.out.junction"

    input:
    // One staging folder per lane (r1/lane1/, r1/lane2/ ...): lanes often share file
    // names (e.g. L001/R1.fastq.gz, L002/R1.fastq.gz), which would otherwise collide.
    tuple val(sample), path(r1, stageAs: 'r1/lane*/*'), path(r2, stageAs: 'r2/lane*/*')
    path index

    output:
    tuple val(sample), path("${sample}.bam"), path("${sample}.bam.bai"), emit: bam
    tuple val(sample), path("${sample}.Log.final.out"),                   emit: log
    path "${sample}.Chimeric.out.junction", optional: true

    script:
    def reads1 = (r1 instanceof List ? r1 : [r1]).join(',')
    def reads2 = (r2 instanceof List ? r2 : [r2]).findAll { f -> f }.join(',')
    // Command lives in the image (containers/counts/scripts/cog_align.sh), shared
    // with bin/cog-ball-run.sh so both routes run identical STAR/samtools commands.
    """
    cog_align.sh ${sample} ${index} ${task.cpus} ${reads1} ${reads2}
    """
}

process COUNT_QC {
    tag "${sample}"
    label 'counts'
    cpus 2
    memory 12.GB
    time '12.h'
    publishDir "${params.outdir}/${params.center}/${sample}/counts", mode: 'copy',
        pattern: "${sample}.{htseq.tsv,htseq.dux4patched.tsv,counts_qc.json,versions.json,rnaseqc.metrics.tsv,genebody.tsv}"

    input:
    tuple val(sample), path(bam), path(bai), path(star_log)
    path gtf
    path collapsed_gtf
    val refs_manifest_sha256

    output:
    tuple val(sample), path("${sample}.htseq.dux4patched.tsv"), emit: counts
    path "${sample}.htseq.tsv"
    path "${sample}.counts_qc.json",                            emit: qc
    path "${sample}.versions.json"
    path "${sample}.rnaseqc.metrics.tsv"
    path "${sample}.genebody.tsv"

    script:
    // Command lives in the image (containers/counts/scripts/cog_count.sh), shared
    // with bin/cog-ball-run.sh.
    """
    cog_count.sh --sample ${sample} --center ${params.center} --bam ${bam} --gtf ${gtf} --collapsed-gtf ${collapsed_gtf} \
        --star-log ${star_log} --manifest-sha ${refs_manifest_sha256} \
        --min-unique-pct ${params.min_unique_pct} --min-assigned ${params.min_assigned} \
        --runner nextflow --run-id ${workflow.runName} --container ${task.container}
    """
}

def checkCenter(String code) {
    def reg = file("${projectDir}/../../centers.tsv")
    if (code == 'TEST' || !reg.exists()) return code   // TEST: reserved for validation runs
    def codes = reg.readLines().drop(1).collect { l -> l.tokenize('\t')[0] }
    if (!(code in codes))
        error "Center '${code}' is not registered in centers.tsv (registered: ${codes.join(', ')}). " +
              "Set CENTER in site.conf (cp site.conf.example site.conf) or ask COG to add your center."
    code
}

def validateId(String id, String what) {
    if (!(id ==~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/))
        error "Invalid ${what} '${id}': use letters, digits, '.', '_' or '-' (no spaces, no PHI)."
    id
}

workflow {
    if (!params.input)  error "Set --input samplesheet.csv"
    if (!params.center) error "Set CENTER in site.conf (cp site.conf.example site.conf) or pass --center (CHOP, NCH, CHLA)"
    if (!params.refs)   error "Set REFS in site.conf or pass --refs (output directory of 00-reference)"
    if (!params.outdir) error "Set --outdir"
    validateId(params.center as String, 'center')
    checkCenter(params.center as String)

    def refs = file(params.refs)
    def index = refs.resolve('star_index')
    def gtf = refs.resolve('genes.gtf')
    def collapsed = refs.resolve('genes.collapsed.gtf')
    def manifest = refs.resolve('reference_manifest.json')
    [index, gtf, manifest].each { f -> if (!f.exists()) error "Reference bundle incomplete: ${f} not found" }
    if (!collapsed.exists()) error "Reference bundle lacks genes.collapsed.gtf (needed for RNA-SeQC QC). Add it with: bin/cog-ball-reference.sh --outdir ${params.refs} --upgrade --sif-dir <sif dir>"
    def manifest_sha = manifest.text.digest('SHA-256')

    reads = channel.fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true, strip: true)
        .map { row ->
            def s = validateId(row.sample as String, 'sample')
            if (!row.fastq_1) error "Sample ${s}: fastq_1 is empty"
            [s, file(row.fastq_1, checkIfExists: true), row.fastq_2 ? file(row.fastq_2, checkIfExists: true) : null]
        }
        // Lanes stay in samplesheet order and R1/R2 stay paired by row.
        .groupTuple()
        .map { s, r1, r2 ->
            def r2s = r2.findAll { f -> f != null }
            if (r2s && r2s.size() != r1.size()) error "Sample ${s}: mix of paired and single-end rows"
            [s, r1, r2s]
        }

    STAR_ALIGN(reads, index)
    COUNT_QC(STAR_ALIGN.out.bam.join(STAR_ALIGN.out.log), gtf, collapsed, manifest_sha)
}
