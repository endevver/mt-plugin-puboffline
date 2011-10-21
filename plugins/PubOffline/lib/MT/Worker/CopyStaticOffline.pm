# Movable Type (r) (C) 2001-2010 Six Apart, Ltd. All Rights Reserved.
# This code cannot be redistributed without permission from www.sixapart.com.
# For more information, consult your Movable Type license.
#
# $Id: Publish.pm 3455 2009-02-23 02:29:31Z auno $

package MT::Worker::CopyStaticOffline;

use strict;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw(gettimeofday tv_interval);
use MT::Util qw( log_time );
use File::Copy::Recursive qw(dircopy);

sub keep_exit_status_for { 1 }

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;

    # Build this
    my $mt = MT->instance;
    my $plugin = MT->component('PubOffline');

    # reset publish timer; don't republish a file if it has
    # this or a later timestamp.
    $mt->publisher->start_time( time );

    # We got triggered to build; lets find coalescing jobs
    # and process them in one pass.

    my @jobs = ($job);
    my $job_iter;
    if (my $key = $job->coalesce) {
        $job_iter = sub {
            shift @jobs || MT::TheSchwartz->instance->find_job_with_coalescing_value($class, $key);
        };
    }
    else {
        $job_iter = sub { shift @jobs };
    }

    my $start  = [gettimeofday];
    my $copied = 0;

    while (my $job = $job_iter->()) {
        # Hash to reload the job as an MT::Object, this gives me access to the
        # columns that PubOffline plugin has added.
        # This of course is a bug and TODO for MT and Melody
        my $mt_job = MT->model('ts_job')->load( $job->jobid );
        my $batch_id = $job->uniqkey;
        my $batch = MT->model('offline_batch')->load($batch_id);

        # Batch record missing? Strange, but ignore and continue.
        unless ($batch) {
            $job->completed();
            next;
        }
        
        $File::Copy::Recursive::CopyLink = 1;
        my $source = MT->instance->config('StaticFilePath');
        my $base_path = $plugin->get_config_value('output_file_path',
                                                  'blog:'.$batch->blog_id);
        my $target = File::Spec->catfile($base_path,"static");
        $copied    = dircopy($source,$target);

        if (defined $copied && $copied > 0) {
            $job->completed();
        } else {
            my $errmsg = $mt->translate("Error copying static files to target directory: [_1]", $target);
            MT::TheSchwartz->debug($errmsg);
            $job->permanent_failure($errmsg);
            require MT::Log;
            $mt->log({
                ($batch->blog_id ? ( blog_id => $batch->blog_id ) : () ),
                message => $errmsg,
                metadata => log_time() . ' ' . $errmsg,
                category => "publish",
                level => MT::Log::ERROR(),
            });
        }
    }

    if ($copied) {
        MT::TheSchwartz->debug($mt->translate("-- finished copying static files ([quant,_1,file,files] in [_2] seconds)", $copied, sprintf("%0.02f", tv_interval($start))));
    }

}

sub grab_for { 60 }
sub max_retries { 0 }
sub retry_delay { 60 }

1;
