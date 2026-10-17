#!/usr/bin/env nextflow
/*
 * COG B-ALL / MD-ALL — step 2: gene counts -> MD-ALL expression classification
 *
 * Runs only MD-ALL's gene-expression classifier (PhenoGraph + SVM against the
 * 1,821-sample reference). Fusion, mutation and RNAseqCNV modules are not run.
 *
 * Input, either:
 *   --counts_dir <outdir>/<center>     picks up <sample>/counts/<sample>.htseq.dux4patched.tsv from 01-counts
 *                                      (default: OUTDIR/CENTER from site.conf)
 *   --input samplesheet.csv            columns sample,counts (any HTSeq-style ENSG<tab>count file)
 *
 *   nextflow run pipelines/02-classify -profile singularity \
 *       --center CHOP --counts_dir /data/cog-ball-results/CHOP --outdir /data/cog-ball-results
 *
 * Output: <outdir>/<center>/<sample>/mdall/<sample>.{mdall.json,mdall.tsv,predictions.tsv,vst.tsv.gz}
 *         <outdir>/<center>/pipeline_info/classify_<timestamp>_summary.tsv
 */
nextflow.enable.dsl = 2

params.input      = null
params.counts_dir = null
// MD-ALL default PhenoGraph feature counts; changing them changes the calls.
params.featureN   = '100,200,300,400,500,600,700,800,900,1000,1058'

process MDALL_CLASSIFY {
    tag "${sample}"
    label 'mdall'
    cpus 4
    memory 12.GB
    time '2.h'
    publishDir "${params.outdir}/${params.center}/${sample}/mdall", mode: 'copy'

    input:
    tuple val(sample), path(counts)

    output:
    path "${sample}.mdall.tsv", emit: row
    path "${sample}.mdall.json"
    path "${sample}.predictions.tsv"
    path "${sample}.vst.tsv.gz"
    path "${sample}.mdall.log"

    script:
    """
    mdall_classify.R \\
        --counts ${counts} \\
        --sample ${sample} \\
        --center ${params.center} \\
        --featureN ${params.featureN} \\
        --cores ${task.cpus} \\
        --outdir . 2>&1 | tee ${sample}.mdall.log
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
    if (!params.center) error "Set CENTER in site.conf (cp site.conf.example site.conf) or pass --center (CHOP, NCH, CHLA)"
    if (!params.outdir) error "Set --outdir"
    // Default input: what 01-counts wrote for this center (OUTDIR/CENTER from site.conf).
    def counts_dir = params.counts_dir ?: (params.input ? null : "${params.outdir}/${params.center}")
    if (!params.input && !file(counts_dir).exists()) error "No counts found: pass --counts_dir (01-counts output for this center) or --input samplesheet.csv"
    validateId(params.center as String, 'center')
    checkCenter(params.center as String)

    if (params.input) {
        counts = channel.fromPath(params.input, checkIfExists: true)
            .splitCsv(header: true, strip: true)
            .map { row -> [validateId(row.sample as String, 'sample'), file(row.counts, checkIfExists: true)] }
    } else {
        counts = channel.fromPath("${counts_dir}/*/counts/*.htseq.dux4patched.tsv", checkIfExists: true)
            .map { f -> [validateId(f.name - '.htseq.dux4patched.tsv', 'sample'), f] }
    }

    MDALL_CLASSIFY(counts)

    def stamp = new java.util.Date().format('yyyyMMdd-HHmmss')
    MDALL_CLASSIFY.out.row
        .collectFile(name: "classify_${stamp}_summary.tsv", keepHeader: true, skip: 1, sort: true,
                     storeDir: "${params.outdir}/${params.center}/pipeline_info")
}
