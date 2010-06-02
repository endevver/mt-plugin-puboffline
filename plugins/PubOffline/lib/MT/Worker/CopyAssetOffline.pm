# Movable Type (r) (C) 2001-2010 Six Apart, Ltd. All Rights Reserved.
# This code cannot be redistributed without permission from www.sixapart.com.
# For more information, consult your Movable Type license.
#
# $Id: Publish.pm 3455 2009-02-23 02:29:31Z auno $

package MT::Worker::CopyAssetOffline;

use strict;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw(gettimeofday tv_interval);
use MT::Util qw( log_time );
use File::Copy::Recursive qw(fcopy);

sub keep_exit_status_for { 1 }

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;

    # Build this
    my $mt = MT->instance;

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
        # The real blog site path was saved previously; grab it!
        use MT::Session;
        my $session = MT::Session::get_unexpired_value(86400, 
                        { id => 'Puboffline blog '.$batch->blog_id, 
                          kind => 'po' });
        my $blog_site_path = $session->data;
        $session->remove;

        my $batch_file_path = $batch->path;
        my $iter = MT->model('asset')->load_iter({blog_id => $batch->blog_id});
        while ( my $asset = $iter->() ) {
            # We need to rebuild the asset file path as the real, "online"
            # path, so that the file can be found.
            my $source = $asset->file_path;
            $source =~ s/$batch_file_path//;
            $source = File::Spec->catfile($blog_site_path,$source);

            my $dest = $asset->file_path;
            $copied = fcopy($source,$dest);
        }

        if (defined $copied && $copied > 0) {
            $job->completed();
        } else {
            my $errmsg = $mt->translate("Error copying assets to target directory: [_1]", $batch->path);
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
