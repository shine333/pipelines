#!/usr/bin/env python3
"""Cronjob for triggering bcl2fastq runs
"""


# standard library imports
import logging
import sys
import os
import argparse
import subprocess

# third party imports
# WARN: need in conda root and snakemake env
#import pymongo

# project specific imports
#
from mongo_status import mongodb_conn
from pipelines import generate_window


__author__ = "Lavanya Veeravalli"
__email__ = "veeravallil@gis.a-star.edu.sg"
__copyright__ = "2016 Genome Institute of Singapore"
__license__ = "The MIT License (MIT)"


# global logger
logger = logging.getLogger(__name__)
handler = logging.StreamHandler()
handler.setFormatter(logging.Formatter(
    '[{asctime}] {levelname:8s} {filename} {message}', style='{'))
logger.addHandler(handler)


def main():
    """main function"""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('-1', "--break-after-first", action='store_true',
                        help="Only process first run returned")
    parser.add_argument('-n', "--dry-run", action='store_true',
                        help="Don't run anything")
    parser.add_argument('-t', "--testing", action='store_true',
                        help="Use MongoDB test-server here and when calling bcl2fastq wrapper (-t)")
    parser.add_argument('-e', "--wrapper-args", nargs="*",
                        help="Extra arguments for bcl2fastq wrapper (prefix leading dashes with X, e.g. X-n for -n)")
    default = 14
    parser.add_argument('-w', '--win', type=int, default=default,
                        help="Number of days to look back (default {})".format(default))
    parser.add_argument('-v', '--verbose', action='count', default=0,
                        help="Increase verbosity")
    parser.add_argument('-q', '--quiet', action='count', default=0,
                        help="Decrease verbosity")
    args = parser.parse_args()

    # Repeateable -v and -q for setting logging level.
    # See https://www.reddit.com/r/Python/comments/3nctlm/what_python_tools_should_i_be_using_on_every/
    # and https://gist.github.com/andreas-wilm/b6031a84a33e652680d4
    # script -vv -> DEBUG
    # script -v -> INFO
    # script -> WARNING
    # script -q -> ERROR
    # script -qq -> CRITICAL
    # script -qqq -> no logging at all
    logger.setLevel(logging.WARN + 10*args.quiet - 10*args.verbose)

    bcl2fastq_wrapper = os.path.join(os.path.dirname(sys.argv[0]), "bcl2fastq.py")

    connection = mongodb_conn(args.testing)
    if connection is None:
        sys.exit(1)
    db = connection.gisds.runcomplete
    #DB Query for Jobs that are yet to be analysed in the epoch window

    # FIXME each run object ideally can have 0 or multiple analysis
    # objects this scripts only kickstarts if no analysis objects are present.
    # (later: if --force-failed is given try again for those with
    # exactly one failed. send email for two fail) Analysis object:
    # initiated:timestamp, ended:timestamp,
    # status:"completed"|"troubleshooting"
    epoch_present, epoch_back = generate_window(args.win)

    results = db.find({"analysis": {"$exists" : 0},
                       "timestamp": {"$gt": epoch_back, "$lt": epoch_present}})
    # results is a pymongo.cursor.Cursor which works like an iterator i.e. dont use len()
    logger.info("Found {} runs".format(results.count()))
    for record in results:
        run_number = record['run']
        logger.debug(record)
        cmd = [bcl2fastq_wrapper, "-r", run_number, "-v"]
        if args.testing:
            cmd.append("-t")
        if args.wrapper_args:
            cmd.extend([x.lstrip('X') for x in args.wrapper_args])
        if args.dry_run:
            logger.warning("Skipped following run: {}".format(' '.join(cmd)))
            continue
        else:
            try:
                logger.info("Executing: {}".format(' '.join(cmd)))
                res = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
                if res:
                    logger.info("bcl2fastq wrapper returned:\n{}".format(
                        res.decode().rstrip()))
            except subprocess.CalledProcessError as e:
                logger.critical("The following command failed with return code {}: {}".format(
                    e.stdout, ' '.join(cmd)))
                logger.critical("Will keep going")
                # continue so that a failed run doesn't count,
                # i.e. args.break_after_first shouldn't be trigger
                continue

        if args.break_after_first:
            logger.warning("Stopping after first sequencing run")
            break

    # close the connection to MongoDB
    connection.close()
    logger.info("Successful program exit")


if __name__ == "__main__":
    main()