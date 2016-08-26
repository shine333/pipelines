#!/bin/bash

# FIXME reimplement in python

# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail

MYNAME=$(basename $(readlink -f $0))

toaddr() {
    if [ $(whoami) == 'userrig' ]; then
        echo "rpd@gis.a-star.edu.sg";
    else
        echo "$(whoami)@gis.a-star.edu.sg";
    fi
}

usage() {
    echo "$MYNAME: run pipeline tests"
    echo " -d: Run dry-run tests"
    echo " -r: Run real-run tests"
}
skip_dry_runs=1
skip_real_runs=1
while getopts "dr" opt; do
    case $opt in
        d)
            skip_dry_runs=0
            ;;
        r)
            skip_real_runs=0
            ;;
        \?)
            usage
            exit 1
            ;;
    esac
done


# readlink resolves links and makes path absolute
test -z "$RPD_ROOT" && exit 1


EXOME_IN_HOUSE_DIR=/mnt/projects/rpd/testing/data/somatic/exome-in-house
EXOME_IN_HOUSE_CFG=$EXOME_IN_HOUSE_DIR/exome-in-house.yaml
EXOME_IN_HOUSE_BED=$EXOME_IN_HOUSE_DIR/SeqCap_EZ_Exome_v3_primary.nochr.bed
EXOME_IN_HOUSE_VAL=$EXOME_IN_HOUSE_DIR/validated_SNVs.vcf.gz


DREAM_WGS_DIR=/mnt/projects/rpd/testing/data/somatic/icgc-tcga-dream-somatic/synthetic.challenge.set3/
DREAM_WGS_NORMAL_BAM=$DREAM_WGS_DIR/normal.bam
DREAM_WGS_TUMOR_BAM=$DREAM_WGS_DIR/tumor.bam
DREAM_WGS_BED=$DREAM_WGS_DIR/19.bed
DREAM_WGS_TRUTH=$DREAM_WGS_DIR/synthetic.challenge.set3.tumor.20pctmasked.chr19.truth.vcf.gz


cd $(dirname $0)
pipeline=$(pwd | sed -e 's,.*/,,')
commit=$(git describe --always --dirty)
test -e Snakefile || exit 1


test_outdir_base=$RPD_ROOT/testing/output/${pipeline}/${pipeline}-commit-${commit}
log=$(mktemp)
COMPLETE_MSG="*** All tests completed ***"
echo "Logging to $log"
echo "Check log if the following final message is not printed: \"$COMPLETE_MSG\""

WRAPPER=./lofreq-somatic.py
wes_cmd_base="$WRAPPER -c $EXOME_IN_HOUSE_CFG -l $EXOME_IN_HOUSE_BED -t WES"
wgs_cmd_base="$WRAPPER --normal-bam $DREAM_WGS_NORMAL_BAM --tumor-bam $DREAM_WGS_TUMOR_BAM -l $DREAM_WGS_BED -t WGS"
echo "FIXME: create targeted version from WES?" 1>&2

# dryruns
#
if [ $skip_dry_runs -ne 1 ]; then
    echo "Dryrun: WES" | tee -a $log
    odir=$(mktemp -d ${test_outdir_base}-wes.XXXXXXXXXX) && rmdir $odir
    eval $wes_cmd_base -o $odir -v --no-run >> $log 2>&1
    pushd $odir >> $log
    EXTRA_SNAKEMAKE_ARGS="--dryrun" bash run.sh >> $log 2>&1
    rm -rf $odir
    popd >> $log

    echo "Dryrun: WGS" | tee -a $log
    odir=$(mktemp -d ${test_outdir_base}-wgs.XXXXXXXXXX) && rmdir $odir
    eval $wgs_cmd_base -o $odir -v --no-run >> $log 2>&1
    pushd $odir >> $log
    EXTRA_SNAKEMAKE_ARGS="--dryrun" bash run.sh >> $log 2>&1
    rm -rf $odir
    popd >> $log
    
else
    echo "Dryruns tests skipped"
fi


# real runs
#
if [ $skip_real_runs -ne 1 ]; then
    echo "Realrun: WES" | tee -a $log
    odir=$(mktemp -d ${test_outdir_base}-wes.XXXXXXXXXX) && rmdir $odir
    eval $wes_cmd_base -o $odir -v >> $log 2>&1
    # magically works even if line just contains id as in the case of pbspro
    jid=$(tail -n 1 $odir/logs/submission.log  | cut -f 3 -d ' ')
    echo "Started $jid writing to $odir. You will receive an email"
    
    jobname="${pipeline}.${MYNAME}.check.WES"
    mailopt="-M $(toaddr) -m bea"
    if qstat --version 2>&1 | grep -q PBSPro; then
        # -cwd not available but all paths are absolute so no need
        # using bash after -- doesn't work: binary expected
        qsub="qsub -q production -l select=1:ncpus=1 -l select=1:mem=1g -l walltime=175:00:00 -j oe -V $mailopt -N $jobname -W depend=afterok:$jid --"
    else
        qsub="qsub -pe OpenMP 1 -l mem_free=1G -l h_rt=01:00:00 -j y -b y -cwd -V $mailopt -N $jobname -hold_jid $jid"
    fi
    echo "Submitting validation hold-job" | tee -a $log
    pred=$odir/out/variants/lofreq_somatic_final.snvs.vcf.gz
    # only subset validated, hence only sens test make sense
    $qsub "$(pwd)/validate.sh -t $EXOME_IN_HOUSE_VAL -p $pred -S 0.85" >> $log 2>&1

    
    echo "Realrun: WGS" | tee -a $log
    odir=$(mktemp -d ${test_outdir_base}-wgs.XXXXXXXXXX) && rmdir $odir
    eval $wgs_cmd_base -o $odir -v >> $log 2>&1
    # magically works even if line just contains id as in the case of pbspro
    jid=$(tail -n 1 $odir/logs/submission.log  | cut -f 3 -d ' ')
    echo "Started $jid writing to $odir. You will receive an email"
    echo "FIXME: submit test against?" 1>&2
else
    echo "Real-run test skipped"
fi


echo
echo "$COMPLETE_MSG"

