#!/hpc-home/vof23jop/mambaforge/envs/nextflow/bin/nextflow

def baseDir = System.getProperty("user.dir")

/*
=================================
= Primer Design Nextflow Script =
=================================
*/

def helpMessage() {
    log.info """
    ==========${"="*version.length()}==
    = Version ${version} =
    ==========${"="*version.length()}==
    
    Usage:
    ./main.nf
    


    """.stripIndent()
}

version = "0a"
nextflow.enable.dsl=2

// if (params.help) {
//     helpMessage()
//     exit(0)
// }

host = Channel.fromPath( "${baseDir}/assets/refs/host/GCF_018294505.1.fna" )
pgt_refs = Channel.fromPath("${baseDir}/assets/refs/pgt_all/*.fna")
pst_refs = Channel.fromPath("${baseDir}/assets/refs/pst_all/*.fna")
waitings = Channel.from("${baseDir}/data/*/wait_*")

workflow {
    pgt_all = pgt_refs.collectFile(name: 'pgt_all.fna', newLine: true)
    pst_all = pst_refs.collectFile(name: 'pst_all.fna', newLine: true)

    rusts = Channel.from("pgt", "pst")
    isols = Channel.from("210","104")
    rusts1 = Channel.from("pgt", "pst")
    rusts2 = Channel.from("pgt", "pst")

    genes_ch = ExtractValidGenes(rusts, isols)

    blast_ch = BlastSearch(ExtractValidGenes.out.genes_out.collect(), rusts, pgt_refs, pst_refs)

    FindConservedSites(BlastSearch.out.blast_out.collect(), rusts)

    DesignPrimers(FindConservedSites.out.conservedsites_out.collect(), rusts, host, pgt_all, pst_all)
}
//    CleanUp(rusts, waitings)

process ExtractValidGenes {
    tag "$rust"
    beforeScript "rm -f ${baseDir}/assets/refs/*/sorted_*.fna"
    publishDir "${baseDir}/data/genes/", mode: 'copy'

    input:
    val rust
    val isol

    output:
    path "${rust}_genes.fna", emit: genes_out


    script:
    def rust_list = "${baseDir}/${rust}_genes.txt" 
    def isol_gff = "${baseDir}/assets/refs/${rust}${isol}/*.gff"
    def isol_fa = "${baseDir}/assets/refs/${rust}${isol}/*.fna" 
    """
    extract_genes_validate.py $isol_fa $isol_gff $rust_list ${rust}_genes.fna
    """
}

process BlastSearch {
    tag "$rust"
    publishDir "${baseDir}/data/blast_results/", mode: 'copy'

    input:
    val complete_genes
    val rust
    each pgt_refs
    each pst_refs

    output:
    path "*_blast.out", emit: blast_out


    // This script is a bit of a mess, but it works. The issue I kept facing was that the processes take place in
    // parallel, so the blastn command was run before the files were created. These conditional arguments make sure
    // that the blastn command is only run when the pgt/pst gene fnas exist in the directory, and that the name of
    // the blast output file corresponds to the name of the reference file.

    script:
    def pgt_fna = pgt_refs.getBaseName().toString()
    def pst_fna = pst_refs.getBaseName().toString()
    def pgt_genes = "${baseDir}/data/genes/pgt_genes.fna"
    def pst_genes = "${baseDir}/data/genes/pst_genes.fna"
    """
    if [[ "${rust}" == "pgt" ]]; then
        blastn -query $pgt_genes -subject $pgt_refs -outfmt  "6 qseqid sseqid pident bitscore sstart send sseq"  -out ${rust}_${pgt_fna}_blast.out
    elif [[ "${rust}" == "pst" ]]; then
        blastn -query $pst_genes -subject $pst_refs -outfmt  "6 qseqid sseqid pident bitscore sstart send sseq"  -out ${rust}_${pst_fna}_blast.out
    else
        touch wait_blast.out
    fi
    """
}

process FindConservedSites {
    tag "$rust"
    publishDir "${baseDir}/data/conserved_sites/", mode: 'copy'

    input:
    val complete_blast_outs
    val rust

    output:
    path "*_conserved_sites.fna", emit: conservedsites_out

    // Again, same issue as above, and similarly structured solution.

    script:
    def blast_out = "${baseDir}/data/blast_results/"
    def pgt_genes = "${baseDir}/data/genes/pgt_genes.fna"
    def pst_genes = "${baseDir}/data/genes/pst_genes.fna"
    """
    if [[ "${rust}" == "pgt" ]]; then
        conserved_sites.py ${rust} $blast_out $pgt_genes pgt_conserved_sites.fna
    elif [[ "${rust}" == "pst" ]]; then
        conserved_sites.py ${rust} $blast_out $pst_genes pst_conserved_sites.fna
    else
        touch wait_conserved_sites.fna
    fi
    """
}

process DesignPrimers {
    tag "$rust"
    beforeScript "rm -f ${baseDir}/assets/refs/*/sorted_*.fna"
    publishDir "${baseDir}/hpc-out", mode: 'copy'

    input:
    val conservedsites_outs
    each rust
    path host
    path pgt_all
    path pst_all

    // This is a mess, but can't think of another way to run this in parallel for each gene
    script:
    def isol_gff = "${baseDir}/assets/refs"
    def conserved_dir = "${baseDir}/data/conserved_sites"
    def blast_out = "${baseDir}/data/blast_results/"
    def direction = "forward"    
    """
    if [[ "${rust}" == "pgt" ]]; then
        bash ${baseDir}/bin/hpc/0-gettmp.sh $rust $conserved_dir/pgt_conserved_sites.fna ${baseDir}
        sbatch ${baseDir}/bin/hpc/1-parallel.sh $rust $isol_gff/pgt210 $host $direction $blast_out $pgt_all ${baseDir}/data/primers/pgt ${baseDir}
    elif [[ "${rust}" == "pst" ]]; then
        bash ${baseDir}/bin/hpc/0-gettmp.sh $rust $conserved_dir/pst_conserved_sites.fna ${baseDir}
        sbatch ${baseDir}/bin/hpc/1-parallel.sh $rust $isol_gff/pst104 $host $direction $blast_out $pst_all ${baseDir}/data/primers/pst ${baseDir}
    else
        touch data/primers/wait_primers.csv
    fi
    """
}

process CleanUp {
    cache false

    input:
    val rust
    each waitings

    script:
    """
    rm -f $waitings
    """
}
