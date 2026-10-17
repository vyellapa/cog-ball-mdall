# syntax=docker/dockerfile:1
#
# cog-ball/mdall — R 4.4 + MD-ALL (expression classifier only) + the COG wrapper
# scripts and the fixed reference assets (UMAP model, reference VST matrix).
# Used by pipelines/02-classify, and as the source of the reference assets for the
# web image.
#
# Build:  containers/build_images.sh          (reads ../../VERSION)
#
# Base: Bioconductor 3.20 on R 4.4 (Ubuntu 24.04), multi-arch. On linux/amd64 it
# installs pre-built binaries; on arm64 (local testing on Apple Silicon) packages
# compile from source and the build takes much longer.

FROM bioconductor/bioconductor_docker:RELEASE_3_20

# Networks with TLS inspection (e.g. Cisco Umbrella) re-sign HTTPS with their own CA.
# build_images.sh passes that CA as an optional BuildKit secret; it is used only while
# downloading and never stored in the image.
ARG CA_SETUP='if [ -s /run/secrets/extra_ca ]; then cat /etc/ssl/certs/ca-certificates.crt /run/secrets/extra_ca > /tmp/ca.pem; export CURL_CA_BUNDLE=/tmp/ca.pem SSL_CERT_FILE=/tmp/ca.pem; fi'

# CRAN/Bioconductor packages MD-ALL imports, plus what the wrapper scripts use.
RUN --mount=type=secret,id=extra_ca,required=false eval "$CA_SETUP" && Rscript -e ' \
  pkgs <- c("dplyr","stringr","tidyr","optparse","jsonlite","vroom","uwot","remotes", \
            "SummarizedExperiment","DESeq2","SingleR","missForest","ggplot2","ggrepel", \
            "cowplot","caret","Seurat","irlba","igraph","LiblineaR","umap","shiny", \
            "shinydashboard","shinyjs","shinyFeedback","data.table","randomForest"); \
  options(timeout = 600); \
  for (attempt in 1:4) { \
    missing <- setdiff(pkgs, rownames(installed.packages())); \
    if (!length(missing)) break; \
    message("Install attempt ", attempt, ": ", paste(missing, collapse = ", ")); \
    BiocManager::install(missing, ask = FALSE, update = FALSE, Ncpus = parallel::detectCores()) \
  }; \
  missing <- setdiff(pkgs, rownames(installed.packages())); \
  if (length(missing)) stop("Failed to install: ", paste(missing, collapse = ", ")) \
' && rm -rf /tmp/Rtmp* /tmp/downloaded_packages /tmp/ca.pem

# MD-ALL and Rphenograph pinned to exact commits, fetched as tarballs (no GitHub API).
ARG MDALL_COMMIT=3047c050f9945acad2c6b413f46f378369c47460
ARG RPHENOGRAPH_COMMIT=0298487f0ee13aac55eb77d19992f6bd878ba2fc
RUN --mount=type=secret,id=extra_ca,required=false eval "$CA_SETUP" && Rscript -e ' \
  gh <- function(repo, sha) sprintf("https://github.com/%s/archive/%s.tar.gz", repo, sha); \
  remotes::install_url(gh("JinmiaoChenLab/Rphenograph", Sys.getenv("RPHENOGRAPH_COMMIT")), upgrade = "never"); \
  remotes::install_url(gh("gu-lab20/MD-ALL", Sys.getenv("MDALL_COMMIT")), upgrade = "never"); \
  suppressPackageStartupMessages({library(Rphenograph); library(MDALL)}); \
  stopifnot(exists("obj_1821"), exists("obj_234_HTSeq"), exists("models_svm")) \
' && rm -rf /tmp/Rtmp* /tmp/downloaded_packages /tmp/ca.pem

ENV MDALL_COMMIT=${MDALL_COMMIT} \
    COG_BALL_REF=/opt/cog-ball/ref \
    PATH=/opt/cog-ball/bin:$PATH

COPY scripts/ /opt/cog-ball/bin/
RUN chmod 755 /opt/cog-ball/bin/*.R \
 && Rscript /opt/cog-ball/bin/build_reference_assets.R /opt/cog-ball/ref \
 && chmod -R a+rX /opt/cog-ball

ARG COG_BALL_VERSION=dev
ENV COG_BALL_VERSION=${COG_BALL_VERSION}
LABEL org.opencontainers.image.title="cog-ball-mdall" \
      org.opencontainers.image.version="${COG_BALL_VERSION}" \
      org.opencontainers.image.description="MD-ALL (gu-lab20, expression classifier only) for COG B-ALL classification"

CMD ["mdall_classify.R", "--help"]
