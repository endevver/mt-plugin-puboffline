package PubOffline::Worker::HandleStatic;

use strict;
use warnings;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw( gettimeofday tv_interval );
use PubOffline::Util qw( get_output_path );
use File::Basename;
use File::Copy::Recursive qw( dircopy );
use File::Find;
use MT::FileMgr;

sub keep_exit_status_for { 1 }

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $plugin = MT->component('PubOffline');

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

        # We need the blog ID below. It can be parsed out of the coalesce
        # column of the job.
        my @coalesce_values = split(/[:]/, $mt_job->coalesce);
        my $blog_id = $coalesce_values[0];

        # The source path was set in the job's uniqkey.
        my $source = $job->uniqkey;

        my $static_file_path = MT->config('StaticFilePath');
        $static_file_path = $static_file_path . '/' 
            if $static_file_path !~ /\/$/;

        # Create a relative path that can be used to properly create the online
        # and offline paths.
        my $rel_file_path = $source;
        $rel_file_path =~ s/$static_file_path//;

        my $output_file_path = get_output_path({ 
            blog_id => $blog_id,
        });

        my $dest = File::Spec->catfile($output_file_path, 'static', $rel_file_path);

        # How is this blog supposed to handle assets: copy or hard link?
        my $pref = $plugin->get_config_value(
            'static_handling',
            'blog:' . $blog_id,
        );

        if ($pref eq 'hard_link') {
            my $fmgr = MT::FileMgr->new('Local')
                or die MT::FileMgr->errstr;

            # Use File::Find to traverse the file and folder structure at the
            # specified folder. This will recursively search the $source for
            # any files that are needed. $File::Find::name contains the
            # absolute path to the file.
            find sub {
                # Give up if this is a directory; we only need files.
                return if -d $File::Find::name;

                $rel_file_path = $File::Find::name;
                $rel_file_path =~ s/$static_file_path//;

                # Create the destination path
                $dest = File::Spec->catfile(
                    $output_file_path, 
                    'static', 
                    $rel_file_path,
                );

                # If the file already exists, just give up. No point in trying
                # to recreate a link that already exists.
                return if -e $dest;

                # Grab the path to the file (undef is the filename).
                my (undef, $path) = fileparse($dest);

                # Create the parent directory structure before trying to
                # link the file.
                $fmgr->mkpath( $path )
                    or die MT::FileMgr->errstr;

                # Finally, create the hard link.
                my $result = link( $File::Find::name, $dest );

                # If the link wasn't successfully created, log it.
                if (!$result) {
                    my $errmsg = 'PubOffline: Error hard linking static '
                        . 'files to target directory: ' . $dest;

                    MT::TheSchwartz->debug($errmsg);

                    MT->log({
                        message => $errmsg,
                        level   => MT::Log::ERROR(),
                        blog_id => $blog_id,
                    });
                }
            }, $source;

            $copied++;
        }
        # Fall back to copying the asset.
        else {
            $File::Copy::Recursive::CopyLink = 1;
            my $result = dircopy( $source, $dest );

            if (!$result) {
                my $errmsg = $mt->translate(
                    "PubOffline: Error copying static files to target "
                    . "directory: [_1]", 
                    $dest
                );

                MT::TheSchwartz->debug($errmsg);

                MT->log({
                    message => $errmsg,
                    level   => MT::Log::ERROR(),
                    blog_id => $blog_id,
                });
            }
            else {
                $copied++;
            }
        }

        if (defined $copied && $copied > 0) {
            $job->completed();

            my $msg = $mt->translate(
                "PubOffline finished copying static files from $source."
            );

            MT::TheSchwartz->debug($msg);

            MT->log({
                message => $msg,
                level   => MT::Log::INFO(),
                blog_id => $blog_id,
            });
        }
    }

}

sub grab_for { 60 }
sub max_retries { 0 }
sub retry_delay { 60 }

1;

__END__
