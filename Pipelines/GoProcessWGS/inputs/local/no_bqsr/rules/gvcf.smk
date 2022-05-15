
rule scatter_intervals:
    output:
        acgt_ivals  = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/acgt.N50.interval_list",
    params:
        ref_fasta    = config['ref_fasta'],
        contig_ns    = config['contig_n_size'],
    threads: 1
    resources:
         time   = 20,
         mem_mb = 8000
    shell:
        '''
            java -jar /opt/wags/src/picard.jar \
                ScatterIntervalsByNs \
                R={params.ref_fasta} \
                OT=ACGT \
                N={params.contig_ns} \
                O={output.acgt_ivals}
        '''

checkpoint split_intervals:
    input:
        acgt_ivals  = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/acgt.N50.interval_list",
    output:
        directory("{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/scattered")
    params:
        ref_fasta    = config['ref_fasta'],
        scatter_size = config['scatter_size'],
       #split_dir    = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/scattered"
    threads: 1
    resources:
         time   = 20,
         mem_mb = 8000
    shell:
        '''
            gatk SplitIntervals \
                -R {params.ref_fasta} \
                -L {input.acgt_ivals} \
                --scatter-count {params.scatter_size} \
                --subdivision-mode BALANCING_WITHOUT_INTERVAL_SUBDIVISION \
                -O {output}
        '''

def get_gvcfs(wildcards):
    # interval dir from split intervals
    ivals_dir = checkpoints.split_intervals.get(**wildcards).output[0]
    # variable number of intervals up to scatter_size set in config (default: 50)
    SPLIT, = glob_wildcards(os.path.join(ivals_dir,"00{split}-scattered.interval_list"))
    # return list of split intervals
    return expand(os.path.join(ivals_dir,"{sample_name}.00{split}.g.vcf.gz"),sample_name=sample_name,split=SPLIT)

#rule hc_intervals:
#    output:
#        acgt_ivals  = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/acgt.N50.interval_list",
#        split_ivals = expand(
#            "{{bucket}}/wgs/{{breed}}/{{sample_name}}/{{ref}}/gvcf/hc_intervals/scattered/00{split}-scattered.interval_list",
#            split=list(map("{:02d}".format, list(range(0,config['scatter_size']))))
#        )
#    params:
#        contig_ns    = config['contig_n_size'],
#        scatter_size = config['scatter_size'],
#        ref_fasta    = config['ref_fasta'],
#        split_dir    = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/scattered"
#    threads: 1
#    resources:
#         time   = 20,
#         mem_mb = 8000
#    shell:
#        '''
#            set -e
#
#            java -jar /opt/wags/src/picard.jar \
#                ScatterIntervalsByNs \
#                R={params.ref_fasta} \
#                OT=ACGT \
#                N={params.contig_ns} \
#                O={output.acgt_ivals}
#
#            gatk SplitIntervals \
#                -R {params.ref_fasta} \
#                -L {output.acgt_ivals} \
#                --scatter-count {params.scatter_size} \
#                --subdivision-mode BALANCING_WITHOUT_INTERVAL_SUBDIVISION \
#                -O {params.split_dir}
#        '''

rule haplotype_caller:
    input:
        sorted_bam = "{bucket}/wgs/{breed}/{sample_name}/{ref}/bam/{sample_name}.{ref}.aligned.duplicate_marked.sorted.bam" 
            if not config['left_align'] else "{bucket}/wgs/{breed}/{sample_name}/{ref}/bam/{sample_name}.{ref}.left_aligned.duplicate_marked.sorted.bam",
        sorted_bai = "{bucket}/wgs/{breed}/{sample_name}/{ref}/bam/{sample_name}.{ref}.aligned.duplicate_marked.sorted.bai"
            if not config['left_align'] else "{bucket}/wgs/{breed}/{sample_name}/{ref}/bam/{sample_name}.{ref}.left_aligned.duplicate_marked.sorted.bai",
        interval  = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/scattered/00{split}-scattered.interval_list"
    output:
        hc_gvcf = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/scattered/{sample_name}.00{split}.g.vcf.gz"
    params:
        java_opt  = "-Xmx10G -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10",
        ref_fasta = config['ref_fasta'],
    benchmark:
        "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/benchmarks/{sample_name}.00{split}.hc.benchmark.txt"
    threads: 4
    resources:
         time   = 720,
         mem_mb = 8000
    shell:
        '''
            gatk --java-options "{params.java_opt}" \
                HaplotypeCaller \
                -R {params.ref_fasta} \
                -I {input.sorted_bam} \
                -L {input.interval} \
                -O {output.hc_gvcf} \
                -contamination 0 -ERC GVCF
        '''

rule merge_gvcfs:
    input:
       #hc_gvcfs = sorted(
       #    expand(
       #        "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/hc_intervals/scattered/{sample_name}.00{split}.g.vcf.gz",
       #        bucket=config["bucket"],
       #        ref=config['ref'],
       #        breed=breed,
       #        sample_name=sample_name,
       #        split=list(map("{:02d}".format, list(range(0,config['scatter_size']))))
       #        ), key=lambda item: int(os.path.basename(item).split(".")[1])
       #)
        get_gvcfs
    output:
        final_gvcf     = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/{sample_name}.{ref}.g.vcf.gz",
        final_gvcf_tbi = "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/{sample_name}.{ref}.g.vcf.gz.tbi",
    params:
        gvcfs     = lambda wildcards, input: " -INPUT ".join(map(str,input)),
        java_opt  = "-Xmx2000m",
        ref_fasta = config['ref_fasta'],
    benchmark:
        "{bucket}/wgs/{breed}/{sample_name}/{ref}/gvcf/{sample_name}.merge_hc.benchmark.txt"
    threads: 4
    resources:
         time   = 120,
         mem_mb = 4000
    shell:
        '''
            gatk --java-options {params.java_opt}  \
                MergeVcfs \
                --INPUT {params.gvcfs} \
                --OUTPUT {output.final_gvcf}
        '''

