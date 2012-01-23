package PubOffline::Worker::OfflineArchive;

use strict;
use warnings;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw( gettimeofday tv_interval );
use PubOffline::Util qw( get_output_path get_archive_path path_exists );
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use MT::Util qw( dirify );
use File::Copy qw( move );
use File::Find;

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

        my $blog_id = $mt_job->uniqkey;

        # Clean-up the offline site by deleting any emtpy folders.
        my $output_file_path  = get_output_path({ blog_id => $blog_id, });
        finddepth(sub { rmdir $_ if -d }, $output_file_path);

        # Create the zip file. Result should contain 
        my $zip_file = _zip_offline({ blog_id => $blog_id });

        # The zip file wasn't created! Report it and just give up.
        if (!$zip_file) {
            my $errmsg = "Publish Offline was unable to create a zip file.";
            MT::TheSchwartz->debug($errmsg);
            $job->permanent_failure($errmsg);
        }

        # Send an email notification about the zip file creation. (But only
        # send an email if one was specified when creating the Schwartz job.)
        my $email_string = $mt_job->arg;
        # There may be many addresses in the string; split them and handle
        # individually.
        my @emails = split( /\s*,\s*/, $email_string);
        foreach my $email (@emails) {
            _send_notification({
                blog_id  => $blog_id,
                zip_file => $zip_file,
                email    => $email,
            });
        }

        # Finally, mark the process as complete!
        $job->completed();
    }
}

# Create a zip of the offline version of the blog.
sub _zip_offline {
    my ($arg_refs) = @_;
    my $blog_id    = $arg_refs->{blog_id};

    my $output_file_path  = get_output_path({ blog_id => $blog_id, });
    my $archive_file_path = get_archive_path({ blog_id => $blog_id, });

    # Make sure that the offline archive path exists.
    my $result = path_exists({
        blog_id => $blog_id,
        path    => $archive_file_path,
    });
    next if !$result; # Give up if the path wasn't created.

    # Craft the zip destination path using a datestamp to make the filename
    # unique. Format the date and time elements to two digits long for
    # consistency.
    my ($sec, $min, $hour, $day, $month, $year) = localtime();
    $year  += 1900;
    $month += 1;
    $month = sprintf("%02d", $month);
    $day   = sprintf("%02d", $day);
    $hour  = sprintf("%02d", $hour);
    $min   = sprintf("%02d", $min);
    $sec   = sprintf("%02d", $sec);

    my $date = "$year-$month-$day-$hour$min$sec";

    # The same archive basename is used for the zip file and for the folder
    # containing the zip file's contents.
    my $blog = MT->model('blog')->load( $blog_id );
    my $archive_name = dirify($blog->name) . '_' . $date;

    # Add the offline version and all files to the zip. Replace
    # the big long path with simply $blog_name.'_offline' so that
    # it can easily be extracted into a directory.
    my $zip = Archive::Zip->new();
    $zip->addTree( $output_file_path, $archive_name );

    my $zip_dest = File::Spec->catfile(
        $archive_file_path, 
        $archive_name . '.zip'
    );

    # Finally, write the zip file to disk.
    if ( $zip->writeToFileNamed($zip_dest.'.tmp') == AZ_OK ) {
        # Success!
        MT->log({ 
            message => "Publish Offline created an archive of the offline " 
                . "version by creating a zip archive at $zip_dest.",
            blog_id => $blog_id,
            level   => MT::Log::INFO()
        });

        # After writing the zip file to disk, rename it from the temporary
        # name to the "real" name. This rename operation keeps incomplete
        # archives off of the Manage Offline Archives listing screen until
        # they are complete.
        my $result = move( $zip_dest.'.tmp', $zip_dest );
        if ($result) {
            return $zip_dest;
        }
    }

    # Failed to write the zip to the temp destination path, or failed to move
    # the temp zip to the "real" path.
    MT->log({ 
        message => "Publish Offline was unable to create a zip archive "
            . "at $zip_dest. Check folder permissions before retrying.",
        blog_id => $blog_id,
        level   => MT::Log::ERROR()
    });
    return 0;
}

# Send an email notification that the zip file has been created.
sub _send_notification {
    my ($arg_refs) = @_;
    my $blog_id    = $arg_refs->{blog_id};
    my $zip_file   = $arg_refs->{zip_file};
    my $email      = $arg_refs->{email};

    my $blog = MT->model('blog')->load( $blog_id );

    require MT::Mail;
    my %head = ( 
        To      => $email, 
        Subject => '[' . $blog->name . '] Offline Archive Created',
    );
    
    my $app_url = MT->config('CGIPath') . MT->config('AdminScript');
    # If $app_url doesn't start `http...` then CGIPath is specified as a
    # root relative URL. Try to build a valid fully-qualified URL to be
    # included in the email.
    if ($app_url !~ /^http/) {
        my $domain = $blog->site_url;
        $domain =~ s/(^https?\:\/\/[^\/]*)(.*)/$1/i;
        $app_url = $domain . $app_url;
    }

    my $body = "The offline zip archive creation process has completed, and "
        . "$zip_file has been created.\n\n"
        . "The offline zip archive may be downloaded at:\n\n"
        . $app_url . "?__mode=po_dl_archive&file=$zip_file\n\n"
        . "Manage this and other offline archives at " 
        . $app_url . "?__mode=po_manage&blog_id=$blog_id";

    MT::Mail->send(\%head, $body)
        or die MT->log({
            message => "Publish Offline couldn't send a notification email: "
                . MT::Mail->errstr,
            blog_id => $blog_id,
            level   => MT->model('log')->ERROR(),
        });
    
    MT->log({
        message => "Publish Offline sent a notification email to $email "
            . "about the creation of the archive $zip_file.",
        blog_id => $blog_id,
        level   => MT->model('log')->ERROR(),
    });
}

sub grab_for { 60 }
sub max_retries { 0 }
sub retry_delay { 60 }

1;

__END__
