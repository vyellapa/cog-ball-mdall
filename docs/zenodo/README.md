# ball_cog_reference v__VERSION__: COG B-ALL MD-ALL reference bundle

Ready-made reference for the COG B-ALL MD-ALL pipeline: STAR 2.7.11b index of the GRCh38
no-alt analysis set + hs38d1, Ensembl 102 annotation restricted to the 60,616 genes in
MD-ALL's reference, a collapsed annotation for RNA-SeQC QC, and checksums.

Zenodo stores files without folders, so `star_index/X` is stored as `star_index__X`.
Install with the pipeline, which restores the folder layout and checks every file
against `SHA256SUMS`:

    bin/cog-ball-reference.sh --download --zenodo <record id> --zenodo-link-token <token>

Derived only from public reference data (NCBI GRCh38, Ensembl release 102). No patient
data. Research use only. See LICENSE.
