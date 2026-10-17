#!/usr/bin/env Rscript
# MD-ALL gene-expression (GEP) classification of ONE sample.
#
# Runs only the expression classifier of MD-ALL (gu-lab20/MD-ALL): DESeq2 VST
# against the 234-sample HTSeq reference, imputation of missing key features,
# PhenoGraph clustering with the 1,821-sample reference over several feature
# counts, and the bundled SVM models. Fusion, mutation and RNAseqCNV modules are
# not run.
#
# Each sample is normalised on its own (batch of one). DESeq2's blind VST over the
# reference plus a batch of query samples would make a sample's values depend on
# which other samples were in the run; one-at-a-time keeps every center's result
# for a sample identical regardless of how runs are grouped.
#
# Outputs (in --outdir):
#   <sample>.mdall.json         full result + QC + provenance (read by the website)
#   <sample>.mdall.tsv          one row; first 10 columns match the classic MDall_output_*.txt
#   <sample>.predictions.tsv    per-method, per-feature-count calls
#   <sample>.vst.tsv.gz         VST expression for every reference gene (gene search)

suppressPackageStartupMessages({
  library(optparse)
  library(dplyr)
  library(stringr)
  library(SummarizedExperiment)
  library(Rphenograph)
  library(MDALL)
  library(jsonlite)
})

opt <- parse_args(OptionParser(option_list = list(
  make_option("--counts",  type = "character", help = "Gene counts: ENSG id <tab> count (HTSeq format; header optional)"),
  make_option("--sample",  type = "character", help = "Sample id"),
  make_option("--center",  type = "character", help = "Center id"),
  make_option("--outdir",  type = "character", default = "."),
  make_option("--featureN", type = "character", default = "100,200,300,400,500,600,700,800,900,1000,1058",
              help = "PhenoGraph feature counts [MD-ALL default]"),
  make_option("--ref-dir", type = "character", default = Sys.getenv("COG_BALL_REF", "/opt/cog-ball/ref"),
              help = "Reference assets built into the image (UMAP model)"),
  make_option("--cores",   type = "integer", default = 1),
  make_option("--min-features", type = "integer", default = 15000,
              help = "Fail if fewer reference genes are present in the counts")
)))

stopifnot(!is.null(opt$counts), !is.null(opt$sample), !is.null(opt$center))
dir.create(opt$outdir, showWarnings = FALSE, recursive = TRUE)
feature_n <- as.integer(strsplit(opt$featureN, ",")[[1]])
started <- Sys.time()
sample_id <- opt$sample
# MD-ALL mangles some characters in sample names (e.g. '-' -> '.'), so the sample
# is always run under MD-ALL's own placeholder id and renamed in the outputs.
QID <- "TestSample"

msg <- function(...) cat(format(Sys.time(), "[%H:%M:%S] "), sprintf(...), "\n", sep = "")

# ── Read counts ───────────────────────────────────────────────────────────────
raw <- read.table(opt$counts, sep = "\t", header = FALSE, stringsAsFactors = FALSE,
                  quote = "", comment.char = "", colClasses = "character", fill = TRUE)
raw <- raw[, 1:2]
names(raw) <- c("id", "count")
if (is.na(suppressWarnings(as.numeric(raw$count[1])))) raw <- raw[-1, ]   # header row
raw <- raw[!startsWith(raw$id, "__"), ]                                     # HTSeq counters
raw <- raw[!grepl("_PAR_Y$", raw$id), ]                                     # GENCODE chrY PAR copies
raw$feature <- sub("\\..*$", "", raw$id)                                    # drop ENSG version
raw$count <- round(as.numeric(raw$count))
if (anyNA(raw$count)) stop("Non-numeric counts in ", opt$counts)
df_count <- raw %>% group_by(feature) %>% summarise(count = sum(count), .groups = "drop") %>% as.data.frame()
names(df_count) <- c("feature", QID)

ref_features <- rownames(obj_234_HTSeq$SE)
key_features <- obj_234_HTSeq$keyFeatures
n_overlap <- sum(ref_features %in% df_count$feature)
n_key_missing <- sum(!key_features %in% df_count$feature)
total_counts <- sum(df_count[[QID]])
msg("Sample %s: %d genes in file, %d/%d reference genes present, %d/%d key features missing, %.1fM counts",
    sample_id, nrow(df_count), n_overlap, length(ref_features), n_key_missing, length(key_features), total_counts / 1e6)
if (n_overlap < opt$`min-features`) {
  stop(sprintf("Only %d of %d reference genes found. Counts must be keyed by Ensembl gene id (ENSG...).",
               n_overlap, length(ref_features)))
}

# ── MD-ALL GEP ────────────────────────────────────────────────────────────────
set.seed(10)
msg("VST against obj_234_HTSeq")
df_vst <- get_vst_values(obj_in = obj_234_HTSeq, df_count = df_count)

set.seed(10)  # missForest is stochastic; only used when key features are missing
df_vst_i <- f_imputation(obj_ref = obj_234_HTSeq, df_in = df_vst)

feature_genes <- c("CDX2", "CRLF2", "NUTM1", "HLF", "DUX4")
df_feat <- get_geneExpression(df_vst = df_vst, genes = feature_genes)
# Every marker gets a value: NA when the gene is absent from this sample's counts
# (reported as missing, never replaced by an imputed estimate).
gene_exp <- lapply(setNames(nm = feature_genes), function(g) {
  v <- df_feat$Expression[df_feat$Gene == g]
  if (length(v)) round(v[1], 4) else NA_real_
})
missing_markers <- feature_genes[is.na(unlist(gene_exp))]
if (length(missing_markers)) msg("Marker gene(s) not in counts: %s (reported as NA)", paste(missing_markers, collapse = ", "))

msg("Merging into obj_1821 and running PhenoGraph (featureN = %s)", paste(feature_n, collapse = ","))
obj_ <- obj_merge(obj_in = obj_1821, df_in = df_vst_i, assay_name_in = "vst")
df_pg <- get_PhenoGraphPreds(obj_in = obj_, feature_panel = "keyFeatures", SampleLevel = QID,
                             neighbor_k = 10, variable_n_list = feature_n, cores = opt$cores)
msg("Running SVM models")
df_svm <- get_SVMPreds(models_svm, df_in = df_vst_i, id = QID)

pg_call   <- get_pred_result(df_pg);  pg_score  <- get_pred_score(df_pg);  pg_label  <- get_pred_label(df_pg)
svm_call  <- get_pred_result(df_svm); svm_score <- get_pred_score(df_svm); svm_label <- get_pred_label(df_svm)

# MD-ALL states a subtype is assigned automatically only when PhenoGraph and SVM
# agree; otherwise it needs review. That is all this reports — no extra rules.
if (pg_call == svm_call && pg_call != "Unclassified") {
  agreement <- "concordant"; gep_call <- pg_call
} else if (pg_call == "Unclassified" && svm_call == "Unclassified") {
  agreement <- "unclassified"; gep_call <- "Unclassified"
} else {
  agreement <- "discordant"; gep_call <- NA_character_
}
# MD-ALL's own high-expression cut-off for feature genes (get_subtype_final: VST >= 9).
high_exp <- names(gene_exp)[names(gene_exp) %in% c("CDX2", "CRLF2", "NUTM1") & !is.na(unlist(gene_exp)) & unlist(gene_exp) >= 9]

# ── UMAP projection onto the fixed reference embedding ───────────────────────
umap_xy <- c(NA_real_, NA_real_)
umap_model_file <- file.path(opt$`ref-dir`, "ref_umap_model.uwot")
if (file.exists(umap_model_file)) {
  model <- uwot::load_uwot(umap_model_file)
  feats <- readLines(file.path(opt$`ref-dir`, "umap_features.txt"))
  v <- setNames(df_vst_i[[QID]], df_vst_i$feature)[feats]
  if (!anyNA(v)) {
    set.seed(10)
    umap_xy <- as.numeric(uwot::umap_transform(matrix(v, nrow = 1), model, n_threads = 1, n_sgd_threads = 0))
  }
  uwot::unload_uwot(model)
} else {
  msg("No UMAP model at %s; skipping projection", umap_model_file)
}

# ── Outputs ───────────────────────────────────────────────────────────────────
prefix <- file.path(opt$outdir, sample_id)
pred_tbl <- bind_rows(df_pg, df_svm) %>% transmute(sample_id = sample_id, method, featureN, pred)
write.table(pred_tbl, paste0(prefix, ".predictions.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

gz <- gzfile(paste0(prefix, ".vst.tsv.gz"), "w")
write.table(data.frame(feature = df_vst$feature, vst = round(df_vst[[QID]], 4)), gz,
            sep = "\t", quote = FALSE, row.names = FALSE)
close(gz)

row <- data.frame(
  sample_id = sample_id,
  CDX2 = gene_exp$CDX2, CRLF2 = gene_exp$CRLF2, NUTM1 = gene_exp$NUTM1,
  phenoGraph_pred = pg_call, phenoGraph_predScore = pg_score, phenoGraph_predLabel = pg_label,
  svm_pred = svm_call, svm_predScore = svm_score, svm_predLabel = svm_label,
  center_id = opt$center, gep_call = ifelse(is.na(gep_call), "", gep_call), agreement = agreement,
  high_expression = paste(high_exp, collapse = ","),
  key_features_missing = n_key_missing,
  umap_1 = umap_xy[1], umap_2 = umap_xy[2],
  stringsAsFactors = FALSE
)
write.table(row, paste0(prefix, ".mdall.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

pkg_ver <- function(p) tryCatch(as.character(packageVersion(p)), error = function(e) NA)
result <- list(
  schema_version = 1,
  sample_id = sample_id,
  center_id = opt$center,
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  classifier = "MD-ALL gene expression (PhenoGraph + SVM)",
  call = list(gep_call = gep_call, agreement = agreement,
              phenograph = list(call = pg_call, score = pg_score, label = pg_label),
              svm = list(call = svm_call, score = svm_score, label = svm_label)),
  predictions = pred_tbl %>% select(-sample_id),
  feature_genes = gene_exp,
  high_expression = I(high_exp),   # I(): always a JSON array, even with one gene
  umap = list(x = umap_xy[1], y = umap_xy[2]),
  input = list(counts_file = basename(opt$counts),
               counts_md5 = unname(tools::md5sum(opt$counts)),
               genes_in_file = nrow(df_count),
               reference_genes_present = n_overlap,
               reference_genes_total = length(ref_features),
               key_features_missing = n_key_missing,
               key_features_total = length(key_features),
               imputed = n_key_missing > 0,
               total_counts = total_counts),
  parameters = list(featureN = feature_n, neighbor_k = 10, normalisation = "DESeq2 VST, one sample + obj_234_HTSeq"),
  provenance = list(pipeline_version = Sys.getenv("COG_BALL_VERSION", "dev"),
                    mdall_repo = "https://github.com/gu-lab20/MD-ALL",
                    mdall_commit = Sys.getenv("MDALL_COMMIT", NA),
                    r = R.version.string,
                    packages = lapply(setNames(nm = c("MDALL", "DESeq2", "Rphenograph", "missForest",
                                                      "caret", "LiblineaR", "uwot", "igraph")), pkg_ver),
                    runtime_sec = round(as.numeric(difftime(Sys.time(), started, units = "secs")), 1))
)
writeLines(toJSON(result, auto_unbox = TRUE, pretty = TRUE, na = "null", digits = NA),
           paste0(prefix, ".mdall.json"))

msg("Done: %s  PhenoGraph=%s (%.2f)  SVM=%s (%.2f)  -> %s [%s]",
    sample_id, pg_call, pg_score, svm_call, svm_score, ifelse(is.na(gep_call), "review", gep_call), agreement)
