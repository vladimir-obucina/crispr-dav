#!/bin/env perl
# Process one sample
# xwang

use strict;
use Getopt::Long;
use FindBin qw($Bin);
use lib "$Bin/Modules";
use NGS;
use Exon;
use Util;
use Data::Dumper;

my %h = get_input();

my $ngs = new NGS(java=>$h{java}, samtools=>$h{samtools},
		bedtools=>$h{bedtools}, bwa=>$h{bwa},
		tmpdir=>$h{tmpdir}, verbose=>$h{verbose});

my $outdir = $h{outdir};
my $sample = $h{sample};
my $read1_outfile="$outdir/$sample.R1.fastq.gz";
my $read2_outfile="$outdir/$sample.R2.fastq.gz";
my $bamfile = "$outdir/$sample.bam";
my $readcount = "$outdir/$sample.cnt";  # to combine into readcount.txt  
my $readchr = "$outdir/$sample.chr";
my $varstat = "$outdir/$sample.var"; # to use for amplicon-wide plots, snp plots

## filter fastq files
$ngs->filter_reads(read1_inf=>$h{read1fastq},
	read2_inf=>$h{read2fastq},
	read1_outf=>$read1_outfile,
	read2_outf=>$read2_outfile);

## Alignment and processing to create bam file

my $ampbed = "$outdir/$sample.amp.bed";
$ngs->makeBed(chr=>$h{chr}, start=>$h{amplicon_start}, 
	end=>$h{amplicon_end}, outfile=>$ampbed);

my @bamstats = $ngs->create_bam(sample=>$sample, 
	read1_inf=>$read1_outfile, 
	read2_inf=>$read2_outfile, 
	idxbase=>$h{idxbase},
	bam_outf=>$bamfile,
	abra=>$h{abra},
	target_bed=>$ampbed,
	ref_fasta=>$h{ref_fasta},
	realign=>$h{realign},
	picard=>$h{picard},
	mark_duplicate=>1,
	remove_duplicate=>$h{unique},
	chromCount_outfile=>$readchr
	);

## Count reads in processing stages
$ngs->readFlow(bamstat_aref=>\@bamstats, 
	r1_fastq_inf=>$h{read1fastq}, r2_fastq_inf=>$h{read2fastq}, gz=>1,
	bam_inf=>$bamfile, chr=>$h{chr}, start=>$h{amplicon_start}, 
	end=>$h{amplicon_end}, sample=>$sample, outfile=>$readcount);	

## Gather variant stats in amplicon.
$ngs->variantStat (bam_inf=>$bamfile, ref_fasta=>$h{ref_fasta}, 
	outfile=>$varstat, chr=>$h{chr}, start=>$h{amplicon_start}, 
	end=>$h{amplicon_end});

## Determine indel pct and length in each CRISPR site
for my $target_name ( sort split(/,/, $h{target_names}) ) {
	## For target and indels
	my $tseqfile= "$outdir/$sample.$target_name.tgt";
	my $pctfile = "$outdir/$sample.$target_name.pct"; 
	my $lenfile = "$outdir/$sample.$target_name.len"; 
	my $hdrfile	= "$outdir/$sample.$target_name.hdr";
	my $canvasfile="$outdir/$sample.$target_name.can";

	my ($chr, $target_start, $target_end, $t1, $t2, $strand, 
		$hdr_changes) = $ngs->getRecord($h{target_bed}, $target_name);
	$ngs->targetSeq (bam_inf=>$bamfile, min_overlap=>$target_end-$target_start+1, 
		sample=>$sample, ref_name=>$h{genome}, target_name=>$target_name, 
		chr=>$chr, target_start=>$target_start, target_end=>$target_end,
		outfile_targetSeq=>$tseqfile, 
		outfile_indelPct=>$pctfile,
		outfile_indelLen=>$lenfile);

	## Determine HDR efficiency 
	if ( $hdr_changes ) {
		$ngs->categorizeHDR(bam_inf=>$bamfile, chr=>$chr, 
			base_changes=>$hdr_changes,
			sample=>$sample,
			min_mapq=>$h{min_mapq},
			stat_outf=>$hdrfile);
	}

	## prepare data for alignment visualization by Canvas Xpress.
	my $cmd= "$Bin/cxdata.pl --ref_fasta $h{ref_fasta}";
	$cmd .= " --refGene $h{refGene} --geneid $h{geneid}"; 
	$cmd .= " --samtools $h{samtools} $lenfile $canvasfile";
	Util::run($cmd, "Failed to create data for Canvas Xpress");

	## create plots of coverage, insertion and deletion on amplicon
	my $cmd = "$h{rscript} $Bin/R/amplicon.R --inf=$varstat --outf=$outdir/$sample.$target_name";
	$cmd .= " --sub=$sample --hname=$target_name --hstart=$target_start --hend=$target_end";
	$cmd .= " --chr=$h{genome} $chr";	
	Util::run($cmd, "Failed to generate amplicon-wide plots");

	## create a plot of base changes in crispr site and surronding regions
	$cmd = "$h{rscript} $Bin/R/snp.R --inf=$varstat --outf=$outdir/$sample.$target_name.snp.png";
	$cmd .= " --outtsv=$outdir/$sample.$target_name.snp";
	$cmd .= " --sample=$sample --hname=$target_name --hstart=$target_start --hend=$target_end";
	$cmd .= " --chr=$h{genome} $chr";
	Util::run($cmd, "Failed to generate base-change plot");
 
	## create plots of indel length distributions (with and without WT)
	$cmd = "$h{rscript} $Bin/R/indel_length.R $lenfile $outdir/$sample.$target_name.len.png";
	$cmd .= " $outdir/$sample.$target_name.len2.png";
	Util::run($cmd, "Failed to generate indel length distribution plots"); 
}

qx(touch $outdir/$sample.done);

sub get_input {
	my $usage = "$0 [options] sampleName read1FastqFile outdir

	Fastq files must be gzipped.

	All options are required unless indicated otherwise or has default.

	--picard         <str> Path to picard-tools directory containing various jar files
	--abra           <str> Path of ABRA jar file.
	--prinseq        <str> Path of prinseq script.
	--samtools       <str> Path of samtools. Default: executable in PATH
	--bwa            <str> Path of bwa. Default: executable in PATH
	--java           <str> Path of java. Default: executable in PATH
	--bedtools       <str> Path of version 2 bedtools. Default: executable in PATH
	--pysamstats     <str> Path of pysamstats. Default: executable in PATH.
	--rscript        <str> Path of Rscript. Default: executable in PATH.
	--tmpdir         <str> Path of temporary directory. Default: /tmp 

	--read2fastq     <str> Optional. Fastq file of read2

	--min_qual_mean  <int> prinseq parameter. Default: 30
	--min_len        <int> prinseq parameter. Default: 50
	--ns_max_p       <int> prinseq parameter. Default: 3

	--unique         Optional. Remove duplicate reads from bam file. 
	--realign        Optional. Realign reads using ABRA. 
	--min_mapq       <int> Optional. Minimum mapping score for reads to be selected.

	--genome         <str> Genome name.		
	--idxbase        <str> Base name of bwa index.
	--ref_fasta      <str> Reference fasta file.
	--refGene        <str> UCSC refGene formatted-file containing transcript/CDS/exon coordinates.
	--geneid         <str> Refseq gene name which must exist in the refGene file.
	
	--chr            <str> chr sequence ID in genome fasta file
	--amplicon_start <int> amplicon start position. 1-based
	--amplicon_end   <int> amplicon end position. 1-based.

	--target_bed     <int> A bed file of CRISPR sites
	--target_names   <str> Names of the CRISPR sites separated by comma.

	--wing_length    <int> Number of bases on each side of CRISPR to show SNP. Default: 50
	
	--verbose        Optional. For debugging.	
	--help           Optional. To show this message
";

	my %h;	
	GetOptions(\%h, 'picard=s', 'abra=s', 'prinseq=s', 'samtools=s', 'bwa=s',
		'java=s', 'bedtools=s', 'pysamstats=s', 'rscript=s', 'tmpdir=s',
		'read2fastq=s', 'unique', 'realign', 'min_mapq=i',
		'min_qual_mean=i', 'min_len=i', 'ns_max_p=i',
		'genome=s', 'idxbase=s', 'ref_fasta=s', 'refGene=s', 'geneid=s',
		'chr=s', 'amplicon_start=i', 'amplicon_end=i',
		'target_bed=s', 'target_names=s', 
		'wing_length=s', 'verbose', 'help');

	die $usage if @ARGV != 3 or $h{help};		
	($h{sample}, $h{read1fastq}, $h{outdir}) = @ARGV;

	# check required options
	my @required = ('picard', 'abra', 'prinseq', 
		'genome', 'idxbase', 'ref_fasta', 'refGene', 'geneid', 
		'chr', 'amplicon_start', 'amplicon_end', 
		'target_bed', 'target_names');

	foreach my $opt ( @required ) {
		die "Missing required option: $opt\n" if !$h{$opt};
	}	

	## set defaults
	my %defaults = (samtools=>'samtools', java=>'java', bwa=>'bwa', 
		bedtools=>'bedtools', rscript=>'Rscript', tmpdir=>'/scratch', 
		min_qual_mean=>30, min_len=>50, ns_max_p=>3, wing_length=>50);

	foreach my $opt ( keys %defaults ) {
		$h{$opt} = $defaults{$opt} if !defined $h{$opt};
	}	

	return %h;
}
