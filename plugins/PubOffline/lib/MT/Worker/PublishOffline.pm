# Movable Type (r) (C) 2001-2010 Six Apart, Ltd. All Rights Reserved.
# This code cannot be redistributed without permission from www.sixapart.com.
# For more information, consult your Movable Type license.
#
# $Id: Publish.pm 3455 2009-02-23 02:29:31Z auno $

package MT::Worker::PublishOffline;

use strict;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw(gettimeofday tv_interval);
use MT::FileInfo;
use MT::PublishOption;
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

    my $start = [gettimeofday];
    my $rebuilt = 0;

    while (my $job = $job_iter->()) {
        # Hash to reload the job as an MT::Object, this gives me access to the
        # columns that PubOffline plugin has added.
        # This of course is a bug and TODO for MT and Melody
        my $mt_job = MT->model('ts_job')->load( $job->jobid );
        my $fi_id = $job->uniqkey;
        my $fi = MT::FileInfo->load($fi_id);

        # FileInfo record missing? Strange, but ignore and continue.
        unless ($fi) {
            $job->completed();
            next;
        }

        # The real blog site path was saved previously; grab it!
        use MT::Session;
        my $session = MT::Session::get_unexpired_value(86400, 
                        { id   => 'Puboffline blog '.$fi->blog_id, 
                          kind => 'po' });
        my $blog_site_path = $session->data;

        my $batch;
        if ($mt_job->has_column('offline_batch_id')) {
            $batch = MT->model('offline_batch')->load( $mt_job->offline_batch_id );

            my $fp = $fi->file_path;
            $fp =~ s/^$blog_site_path(\/)*//;
            my $np = File::Spec->catfile($batch->path, $fp);
            # TODO - change $fi record to point to different base directory
            $fi->file_path($np);
        } else {
            MT->log( "PubOffline: Apparently, the job does not have the offline_batch_id column" );
        }

        my $priority = $job->priority ? ", priority " . $job->priority : "";

        # Important: prevents requeuing!
        $fi->{'from_queue'} = 1;
        $fi->{'offline_batch'} = $batch;

        my $mtime = (stat($fi->file_path))[9];

        my $throttle = MT::PublishOption::get_throttle($fi);

        # think about-- throttle by archive type or by template
        if ($throttle->{type} == MT::PublishOption::SCHEDULED() ) {
            if (-f $fi->file_path) {
                my $time = time;
                if ($time - $mtime < $throttle->{interval}) {
                    # ignore rebuilding this file now; not enough
                    # time has elapsed for rebuilding this file...
                    $job->grabbed_until(0);
                    $job->driver->update($job);
                    next;
                }
            }
        }

        my $res;
        # Copy assets before any content can be published to the offline
        # folder. This way, assets will be in place and asset tags,
        # (especially <mt:AssetProperty file_size="1">) can work on them.
        $res = _copy_assets($blog_site_path, $batch);
        if ($res) {
            $job->permanent_failure($res);
        }

        $res = _rebuild_from_fileinfo($fi, $batch->path);
        if (defined $res) {
            $job->completed();
            $rebuilt++;
        } else {
            my $error = $mt->publisher->errstr;
            my $errmsg = $mt->translate(
                "PubOffline: Error rebuilding file [_1]" . $fi->file_path . ": " . $error
            );
            MT::TheSchwartz->debug($errmsg);
            $job->permanent_failure($errmsg);
            require MT::Log;
            $mt->log({
                ($fi->blog_id ? ( blog_id => $fi->blog_id ) : () ),
                message => $errmsg,
                metadata => log_time() . ' ' . $errmsg . ":\n" . $error,
                category => "publish",
                level => MT::Log::ERROR(),
            });
        }
    }

    if ($rebuilt) {
        MT::TheSchwartz->debug(
            $mt->translate(
                "-- set complete ([quant,_1,file,files] in [_2] seconds)", 
                $rebuilt, 
                sprintf("%0.02f", tv_interval($start))
            )
        );
    }

}

sub grab_for { 60 }
sub max_retries { 0 }
sub retry_delay { 60 }

# This is lifted from MT::WeblogPublisher, with a few changes.
# Notably, the blog site_path needs to be set to the batch path
# so that the site will output all files to the correct location.
sub _rebuild_from_fileinfo {
    my $pub = MT::WeblogPublisher->new();
    my $offline_path = pop;
    my ($fi) = @_;

    require MT::Blog;
    require MT::Entry;
    require MT::Category;
    require MT::Template;
    require MT::TemplateMap;
    require MT::Template::Context;

    my $at = $fi->archive_type
      or return $pub->error(
        MT->translate( "Parameter '[_1]' is required", 'ArchiveType' ) );

    # callback for custom archive types
    return
      unless MT->run_callbacks(
        'build_archive_filter',
        archive_type => $at,
        file_info    => $fi
      );

    if ( $at eq 'index' ) {
        $pub->rebuild_indexes(
            BlogID   => $fi->blog_id,
            Template => MT::Template->load( $fi->template_id ),
            FileInfo => $fi,
            Force    => 1,
        ) or return;
        return 1;
    }

    return 1 if $at eq 'None';

    my ( $start, $end );
    my $blog = MT::Blog->load( $fi->blog_id )
      if $fi->blog_id;

    # Set the site_path, but don't save it--we don't want to overwrite it.
    $blog->site_path( $offline_path );

    my $entry = MT::Entry->load( $fi->entry_id )
      or return $pub->error(
        MT->translate( "Parameter '[_1]' is required", 'Entry' ) )
      if $fi->entry_id;
    if ( $fi->startdate ) {
        my $archiver = $pub->archiver($at);

        if ( ( $start, $end ) = $archiver->date_range( $fi->startdate ) ) {
            $entry = MT::Entry->load( { authored_on => [ $start, $end ] },
                { range_incl => { authored_on => 1 }, limit => 1 } )
              or return $pub->error(
                MT->translate( "Parameter '[_1]' is required", 'Entry' ) );
        }
    }
    my $cat = MT::Category->load( $fi->category_id )
      if $fi->category_id;
    my $author = MT::Author->load( $fi->author_id )
      if $fi->author_id;

    ## Load the template-archive-type map entries for this blog and
    ## archive type. We do this before we load the list of entries, because
    ## we will run through the files and check if we even need to rebuild
    ## anything. If there is nothing to rebuild at all for this entry,
    ## we save some time by not loading the list of entries.
    my $map = MT::TemplateMap->load( $fi->templatemap_id );
    my $file = $pub->archive_file_for( $entry, $blog, $at, $cat, $map,
        undef, $author );
    if ( !defined($file) ) {
        return $pub->error( $blog->errstr() );
    }
    $map->{__saved_output_file} = $file;

    my $ctx = MT::Template::Context->new;
    $ctx->{current_archive_type} = $at;
    if ( $start && $end ) {
        $ctx->{current_timestamp} = $start;
        $ctx->{current_timestamp_end} = $end;
    }

    my $arch_root =
      ( $at eq 'Page' ) ? $blog->site_path : $blog->archive_path;
    return $pub->error(
        MT->translate("You did not set your blog publishing path") )
      unless $arch_root;

    my %cond;
    $pub->rebuild_file( $blog, $arch_root, $map, $at, $ctx, \%cond, 1,
        FileInfo => $fi, )
      or return;

    1;
}

sub _copy_assets {
    my $blog_site_path = shift;
    my ($batch) = @_;

    # If the assets for this batch have already been copied just give up.
    return if $batch->assets_copied;

    my $iter = MT->model('asset')->load_iter({
        blog_id => $batch->blog_id, 
        class   => '*',
    });
    while ( my $asset = $iter->() ) {
        # Give up if the asset doesn't exist on the file system. No point
        # trying to copy something that doesn't exist!
        next unless $asset->file_path && -e $asset->file_path;

        # We need to rebuild the asset file path as the real, "online"
        # path, so that the file can be found.
        my $rel_file_path = $asset->file_path;
        $rel_file_path =~ s/$blog_site_path//;

        my $source = File::Spec->catfile($blog_site_path, $rel_file_path);
        my $dest   = File::Spec->catfile($batch->path, $rel_file_path);

        # Finally, copy the asset.
        my $copied_asset = fcopy($source,$dest);

        if (!$copied_asset) {
            my $errmsg = MT->translate(
                "PubOffline: Error copying asset ([_1]) to target directory: [_2]", 
                $source, 
                $dest
            );
            MT::TheSchwartz->debug($errmsg);
            MT->log({
                ($batch->blog_id ? ( blog_id => $batch->blog_id ) : () ),
                message => $errmsg,
                metadata => log_time() . ' ' . $errmsg,
                category => "publish",
                level => MT::Log::ERROR(),
            });
            return $errmsg;
        }
    }

    # _copy_assets is actually set up to run for each job found in the ts_job 
    # table. We want it to run once for each batch, but since the batch is 
    # likely the same for each job, _copy_assets is probably running many, 
    # many times. So, with _copy_assets complete, mark the batch so that we 
    # don't need to try copying the same assets again.
    $batch->assets_copied(1);
    $batch->save or die $batch->errstr;
}

1;
