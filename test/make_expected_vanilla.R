#!/usr/bin/env Rscript
# Expected calls for test/classify_samplesheet.csv produced with upstream MD-ALL's
# own functions, exactly as get_GEP_pred() chains them, one sample at a time.
# Regenerate only when MDALL_COMMIT changes (after test/fetch_test_data.sh):
#   Rscript test/make_expected_vanilla.R test/data/classify_samplesheet.csv test/expected_mdall.tsv
suppressPackageStartupMessages({library(dplyr); library(Rphenograph); library(MDALL)})
ss <- read.csv(commandArgs(TRUE)[1], stringsAsFactors = FALSE)
fn <- c(seq(100, 1000, 100), 1058)
out <- bind_rows(lapply(seq_len(nrow(ss)), function(i) {
  f <- ss$counts[i]
  df_count <- read_input(f, delimiter = "\t", header = FALSE)
  df_vst <- get_vst_values(obj_in = obj_234_HTSeq, df_count = df_count)
  set.seed(10); df_vst_i <- f_imputation(obj_ref = obj_234_HTSeq, df_in = df_vst)
  obj_ <- obj_merge(obj_in = obj_1821, df_in = df_vst_i, assay_name_in = "vst")
  pg <- get_PhenoGraphPreds(obj_in = obj_, feature_panel = "keyFeatures", SampleLevel = "TestSample",
                            neighbor_k = 10, variable_n_list = fn)
  svm <- get_SVMPreds(models_svm, df_in = df_vst_i)
  data.frame(sample_id = ss$sample[i],
             phenoGraph_pred = get_pred_result(pg), phenoGraph_predScore = get_pred_score(pg),
             phenoGraph_predLabel = get_pred_label(pg),
             svm_pred = get_pred_result(svm), svm_predScore = get_pred_score(svm),
             svm_predLabel = get_pred_label(svm))
}))
write.table(out, commandArgs(TRUE)[2], sep = "\t", quote = FALSE, row.names = FALSE)
