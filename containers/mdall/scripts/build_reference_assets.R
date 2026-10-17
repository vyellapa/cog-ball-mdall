#!/usr/bin/env Rscript
# Build the fixed reference assets shipped inside the mdall image (and copied into
# the web image). Run once at image build time, so every center and the website use
# byte-identical assets.
#
#   ref_umap_model.uwot   uwot model of the 1,821 reference samples (MD-ALL key features);
#                         query samples are projected with umap_transform, so all
#                         samples from all centers share one coordinate system
#   umap_features.txt     feature order the model expects
#   ref_samples.tsv       reference sample id, subtype labels, UMAP coordinates
#   ref_genes.tsv         row index, Ensembl id, gene symbol of ref_vst.f32
#   ref_vst.f32           reference VST matrix, float32 little-endian, one row per gene
#                         (genes x 1821, row-major) — read by the website's gene search
#   subtype_colors.json   MD-ALL subtype palette (hex)
#   ref_meta.json         dimensions and parameters

suppressPackageStartupMessages({
  library(SummarizedExperiment)
  library(MDALL)
  library(jsonlite)
})

out <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(out)) out <- "/opt/cog-ball/ref"
dir.create(out, showWarnings = FALSE, recursive = TRUE)

se <- obj_1821$SE
vst <- assay(se, "vst")
meta <- as.data.frame(colData(se))

# MD-ALL's own UMAP uses the key features with n_neighbors 10 and min_dist 0.3.
feats <- obj_1821$keyFeatures
x <- t(vst[feats, ])
set.seed(10)
model <- uwot::umap(x, n_neighbors = 10, min_dist = 0.3, n_components = 2, metric = "euclidean",
                    ret_model = TRUE, n_threads = 1, n_sgd_threads = 0, verbose = FALSE)
unlink(file.path(out, "ref_umap_model.uwot"))
invisible(uwot::save_uwot(model, file.path(out, "ref_umap_model.uwot")))
writeLines(feats, file.path(out, "umap_features.txt"))

samples <- data.frame(sample_id = colnames(se), subtype = meta$diag, subtype_detail = meta$diag_raw,
                      subtype_detail2 = meta$diag_raw1, umap_1 = round(model$embedding[, 1], 4),
                      umap_2 = round(model$embedding[, 2], 4), stringsAsFactors = FALSE)
write.table(samples, file.path(out, "ref_samples.tsv"), sep = "\t", quote = FALSE, row.names = FALSE)

g <- info_gtf_hg38[!duplicated(info_gtf_hg38$gene_id), c("gene_id", "gene_name")]
genes <- data.frame(row = seq_len(nrow(vst)) - 1L, gene_id = rownames(vst),
                    gene_name = g$gene_name[match(rownames(vst), g$gene_id)], stringsAsFactors = FALSE)
write.table(genes, file.path(out, "ref_genes.tsv"), sep = "\t", quote = FALSE, row.names = FALSE, na = "")

con <- file(file.path(out, "ref_vst.f32"), "wb")
writeBin(as.numeric(t(vst)), con, size = 4, endian = "little")
close(con)

# MD-ALL's own subtype palette, as hex, so the website matches MD-ALL's figures.
pal <- MDALL:::subtypeCol()
pal_hex <- setNames(as.list(rgb(t(col2rgb(pal)), maxColorValue = 255)), names(pal))
writeLines(toJSON(pal_hex, auto_unbox = TRUE, pretty = TRUE), file.path(out, "subtype_colors.json"))

writeLines(toJSON(list(n_genes = nrow(vst), n_samples = ncol(vst), dtype = "float32", endian = "little",
                       layout = "row-major genes x samples",
                       umap = list(n_neighbors = 10, min_dist = 0.3, seed = 10, features = length(feats)),
                       mdall_commit = Sys.getenv("MDALL_COMMIT", NA),
                       uwot = as.character(packageVersion("uwot"))),
                  auto_unbox = TRUE, pretty = TRUE), file.path(out, "ref_meta.json"))
cat("Reference assets written to", out, "\n")
