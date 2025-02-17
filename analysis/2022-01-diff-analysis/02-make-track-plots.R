# make-plots.R
# Plots tracks for three types of data
# 1. Newly found DMPs
# 2. Regions of interest
# 3. Concordance with other DMPs
suppressPackageStartupMessages({
    library(DSS)
    library(Gviz)
    library(tidyverse)
    library(data.table)
    library(ggsci)
    library(parallel)
    library(scales)
    library(wiscR)
    library(argparse)
    library(methanalyzeR)
    library(Homo.sapiens)
    library(TxDb.Hsapiens.UCSC.hg38.knownGene)
}) 


# CONSTANTS
ALPHA <- 0.01
GEN <- "hg38"
FS <- 16 # fontsize
N <- 5

#Colors for plotting
NCOL <- 7
colors <- pal_nejm("default")(NCOL)

# Parser
parser <- ArgumentParser()
parser$add_argument("--chr", default= "chr6", help='Chromosome to generate figures on')
parser$add_argument("--experiment", default= "/smooth-150-PCs-2/", help='Chromosome to generate figures on')
parser$add_argument("--regions_file", default= "./regions-of-interest.csv", help='CSV specifying other regions to plot')
parser$add_argument("--phenotypes_file", default = "../../data/meta/phenos-cleaned.csv")
parser$add_argument("--odir", default = "/figs/")
args <- parser$parse_args()


# Lazy way to recode variables
CHR <- args$chr
idir <- file.path(paste0("./", CHR, "/"), args$experiment)
odir <- paste0(file.path(idir, "figs/"))
dir.create(odir, showWarnings=FALSE)

# More data
txdb <- TxDb.Hsapiens.UCSC.hg38.knownGene
seqlevels(txdb) <- CHR
TxDb(Homo.sapiens) <- txdb
tx.hs <- unlist(transcriptsBy(Homo.sapiens, columns = "SYMBOL", by = "gene"))
ix <- seqnames(tx.hs) == CHR
tx.hs <- tx.hs[ix, ]

# dbDisconnect()

# Read in data
roi.df <- read_csv(args$regions_file, show_col_types = FALSE)
Meth <- fread(file.path(dirname(idir), "methylation.csv"))
load(file.path(idir, "models.RData"))

# Call DMRs--allow user to input parameters from terminal
dmrs <- callDMR(test.cohort, p.threshold=ALPHA, dis.merge = 2500, pct.sig = 0.5, minCG = 5)
N <- min(N, nrow(dmrs)) # reset N
#--> Split into two groups
load.samples <- filt.df %>% filter(cohort == "AD") %>% pull(sample) %>% as.character()
control.samples <- filt.df %>% filter(cohort == "CONTROL") %>% pull(sample) %>% as.character()


# HELPER FUNCTION ------------------------------------------------------------------------------
prepare_granges <- function(DT, chr=CHR){
    # Munges dataframe (changes column names)
    # to be amenable to GRanges() constructor
    DT.2 <- DT
    
    colnames(DT.2)[colnames(DT.2) == "pos"] <- "start"
    DT.2$end <- DT.2$start + 2
    DT.2$chr <- chr
    return(DT.2)
}

make_gene_track <- function(start, stop, genome=GEN, chr=CHR){
    #out <- GeneRegionTrack(txdb, chromosome = CHR, from = start, to = stop, fontsize = FS, 
    #                        name = "Reference Genes", fill = colors[7], transciptAnnotation = "symbol")

    biomTrack <- BiomartGeneRegionTrack(genome = genome, chromosome = chr, 
                    name = "ENSEMBL", start = start, end = stop, 
                    transciptAnnotation = "symbol", 
                    fontsize = FS, fill = colors[7], showID = TRUE)
    return(biomTrack)
}



# Make common tracks ---------------------------------------------------------------------
Meth.2 <- prepare_granges(Meth)
group <- filt.df$cohort[match(colnames(Meth)[-1], filt.df$sample)]

# "Simple" tracks without too many parameters
dmrs.track <- AnnotationTrack(GRanges(dmrs), genome = GEN, name = "DMRs", 
                            fontsize = FS, fill = colors[3], col = "white")
ideogram.track <- IdeogramTrack(genome = GEN, chromosome = CHR, fontsize = FS - 2)
axis.track <- GenomeAxisTrack()


tmp <- data.frame(start = test.cohort$pos, end = test.cohort$pos + 2, 
                chr = rep(CHR, nrow(test.cohort)), p = -1*log10(test.cohort$pvals))
p.track <- DataTrack(GRanges(tmp), type=c("p", "smooth"), baseline= -log10(0.01), col=colors[1],
                       col.baseline="black", name="-log10(p)", fontsize = FS)

# Tracks from custom functions
diff.track <- make_difference_track(Meth.2, load.samples, control.samples,
                                genome=GEN, chr=CHR, color=colors[6], fontsize=FS)
top.list <- list(ideogram.track) # ontop of genomic information
bottom.list <- list(dmrs.track, p.track, diff.track, axis.track) # below genomic information


create_output_name <- function(odir, nCG, chr, start, pad){
    # odir := output directory
    # nCG := number of CpGs in DMR
    # chr := chromosome 
    # start := starting position of DMR
    bn <- paste0(as.character(nCG), "-", chr, "-start-", as.character(start),"-pad-",as.character(pad), ".pdf")
    return(file.path(odir, bn))
}


plot_and_save <- function(start, stop, tracks.list, ofile){
    # start : starting position
    # stop: stopping position
    # tracks.list: list of tracks to plot, produced beforehand
    # ofile: output
    pdf(ofile)
    plotTracks(tracks.list, from = start, to = stop, background.title = colors[6], 
                collapseTranscripts = "meta", showID = TRUE, transcriptAnnotation = "symbol")
    dev.off()
}

get_gene_track <- function(start, stop, pad){
    a <- start - max(pad)
    b <- stop + max(pad)
    return(make_gene_track(a, b))
}

plot_by_ix <- function(ix, pad=c(1000, 5000, 10000), top=top.list, bottom=bottom.list){
    # For lapply, wrapper for make_gene_track and save...
    a <- dmrs$start[ix]
    b <- dmrs$end[ix]
    nCG <- dmrs$nCG[ix]

    gene.track <- get_gene_track(a,b, pad)
    all.tracks <- append(append(top.list, gene.track), bottom.list)

    for (p in pad){
        ofile <- create_output_name(odir, nCG, CHR, a, p)
        plot_and_save(a-p, b+p, all.tracks, ofile)
    }
}

if (exists("dmrs")){
    if (nrow(dmrs) > 0){
        lapply(1:nrow(dmrs), plot_by_ix)
    }
} 


#--> Regions of interest outside of DMRs
roi.df <-roi.df %>% filter(chr == CHR)
p <- 1000
nCG <- 0

plot_roi_ix <- function(ix){
    a <- roi.df$start[ix]
    b <- roi.df$end[ix]

    odir.tmp <- file.path(odir, roi.df$name[ix])
    dir.create(odir.tmp, showWarnings=FALSE)

    gene.track <- get_gene_track(a,b, p)
    all.tracks <- append(append(top.list, gene.track), bottom.list)
    ofile <- create_output_name(odir.tmp, nCG, CHR, a, p)
    plot_and_save(a-p, b+p, all.tracks, ofile)
}

lapply(1:nrow(roi.df), plot_roi_ix)




# NEAREST GENES --------------------------------------------------------------
format_locus <- function(seq, a, b){
    out <- paste0(seq, ":", as.character(a), "-", as.character(b))
    return(out)
}

tally.input <- data.frame(chr = test.cohort$chr, pos = test.cohort$pos, pvals = test.cohort$pvals, stringsAs = FALSE)
tally_sig_CpGs <- function(a, b){
    tally.input %>% 
        filter(pos >= a) %>% filter(pos <= b) %>%
        filter(pvals <= ALPHA) %>% nrow() %>% return()
}

tally <-  Vectorize(tally_sig_CpGs)
dmrs.2 <- dmrs %>% mutate(nSigCG = tally( start, end))



window <- 10000
# Nearest gene
dmrs.gr <- GRanges(dmrs) 
overlap <- findOverlaps(dmrs.gr + window, unstrand(tx.hs))

tx.hs.shrunk <- tx.hs[subjectHits(overlap), ]
dmrs.gr.expanded <- dmrs.gr[queryHits(overlap), ]

dist <- distanceToNearest(dmrs.gr.expanded, tx.hs.shrunk)
dd <- as.data.frame(dist)$distance

dmrs.df <- as.data.frame(dmrs.gr.expanded, row.names = NULL) %>%
            transmute(dmr.locus = format_locus(seqnames, start, end))

dmrs.df$distance <- dd

ann.df <- as.data.frame(tx.hs.shrunk[, "SYMBOL"], row.names = NULL) %>%
            transmute(gene.locus = format_locus(seqnames, start, end),
             gene.strand = strand, gene.name = SYMBOL)

comb.df <- cbind(dmrs.df, ann.df)


if (nrow(comb.df) == 0){
     # No nearby genes detected
    comb.df <- data.frame(
        dmr.locus = args$chr,
        distance = 0,
        gene.locus = args$chr,
        gene.strand = "*",
        gene.name = "None")
}


# Need to add in rows with blanks... (if there is a DMR that doesn't have annotation)
write_csv(comb.df, file = file.path(idir, "closest-genes.csv"))

# Join the tally with the others
tmp <- dmrs.2 %>% 
    mutate(dmr.locus = format_locus(chr, start, end)) %>%
    full_join(comb.df, by = "dmr.locus") %>%
    dplyr::select(c(dmr.locus, length, nCG, nSigCG, gene.name)) %>%
    unique() %>% group_by(dmr.locus) %>% 
    summarize(dmr.locus, length, nCG, nSigCG, geneNames = paste0(gene.name, collapse = "; ")) %>% 
    rename(dmrLocus = dmr.locus) %>%
    unique() %>% arrange(-nCG)
tmp

write_csv(tmp, file = file.path(idir, "called-dmrs.csv"))
