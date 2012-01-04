package PubOffline::Worker::PublishOffline;

use strict;
use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw(gettimeofday tv_interval);
use MT::FileInfo;
use MT::PublishOption;
use MT::Util qw( log_time );
use PubOffline::Util qw( get_output_path path_exists );
use File::Basename;

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
            # Should this even be logged?
            MT->log({
                level   => MT->model('log')->INFO(),
                message => 'PubOffline: fileinfo record missing. Job ID: ' 
                    . $job->{column_values}->{jobid},
            });
            $job->completed();
            next;
        }

        my $output_file_path = get_output_path({ blog_id => $fi->blog_id });

        my $result = path_exists({
            blog_id => $fi->blog_id,
            path    => $output_file_path,
        });
        next if !$result; # Give up if the path wasn't created.

        my $blog = MT->model('blog')->load( $fi->blog_id );
        my $blog_site_path = $blog->site_path;

        my $fp = $fi->file_path;
        $fp =~ s/^$blog_site_path(\/)*//;
        my $np = File::Spec->catfile($output_file_path, $fp);
        # TODO - change $fi record to point to different base directory
        $fi->file_path($np);

        my $priority = $job->priority ? ", priority " . $job->priority : "";

        # Important: prevents requeuing!
        $fi->{'from_queue'} = 1;

        # So that the build_file_filter callback doesn't happen again.
        $fi->{'is_offline_file'} = 1;

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

        # Rebuild the file.
        my $res = _rebuild_from_fileinfo($fi, $output_file_path);

        if (defined $res) {
            $job->completed();
            $rebuilt++;
        } else {
            my $error = $mt->publisher->errstr;
            my $errmsg = $mt->translate(
                "PubOffline: Error rebuilding file [_1]" 
                . $fi->file_path . ": " . $error
            );
            MT::TheSchwartz->debug($errmsg);
            $job->permanent_failure($errmsg);
            require MT::Log;
            $mt->log({
                ($fi->blog_id ? ( blog_id => $fi->blog_id ) : () ),
                message  => $errmsg,
                metadata => log_time() . ' ' . $errmsg . ":\n" . $error,
                category => "publish",
                level    => MT::Log::ERROR(),
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
# Notably, when publishing index files we need to direct them to our version
# of _rebuild_indexes so that they are published to the right location.
sub _rebuild_from_fileinfo {
    my $pub = MT::WeblogPublisher->new();
    my ($fi) = shift;
    my $output_file_path = shift;

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


    # Index templates get handled a little differently than archives.
    if ( $at eq 'index' ) {
        my $tmpl = MT->model('template')->load( $fi->template_id );
        my $blog = MT->model('blog')->load( $fi->blog_id );

        # Use our _rebuild_indexes (rather than Weblog::Publisher's) so that
        # the output path can be modified as necessary.
        _rebuild_indexes(
            Blog     => $blog,
            Template => $tmpl,
            FileInfo => $fi,
            Force    => 1,
        ) or return;

        return 1;
    }

    return 1 if $at eq 'None';

    my $blog = MT->model('blog')->load( $fi->blog_id );

    my ( $start, $end );
    my $entry = MT->model('entry')->load( $fi->entry_id )
      or return $pub->error(
        MT->translate( "Parameter '[_1]' is required", 'Entry' ) )
      if $fi->entry_id;
    if ( $fi->startdate ) {
        my $archiver = $pub->archiver($at);

        if ( ( $start, $end ) = $archiver->date_range( $fi->startdate ) ) {
            $entry = MT->model('entry')->load( { authored_on => [ $start, $end ] },
                { range_incl => { authored_on => 1 }, limit => 1 } )
              or return $pub->error(
                MT->translate( "Parameter '[_1]' is required", 'Entry' ) );
        }
    }
    my $cat = MT->model('category')->load( $fi->category_id )
      if $fi->category_id;
    my $author = MT->model('author')->load( $fi->author_id )
      if $fi->author_id;

    ## Load the template-archive-type map entries for this blog and
    ## archive type. We do this before we load the list of entries, because
    ## we will run through the files and check if we even need to rebuild
    ## anything. If there is nothing to rebuild at all for this entry,
    ## we save some time by not loading the list of entries.
    my $map = MT->model('templatemap')->load( $fi->templatemap_id );
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

    my %cond;

    $pub->rebuild_file( $blog, $output_file_path, $map, $at, $ctx, \%cond, 1,
        FileInfo => $fi, )
      or return;

    return 1;
}

# This is lifted from MT::WeblogPublisher, with a few changes.
# The offline path needs to be fed when republishing index templates.
sub _rebuild_indexes {
    #my $mt    = shift;
    my $mt = MT->instance;
    my %param = @_;
    require MT::Template;
    require MT::Template::Context;
    require MT::Entry;

    my $blog;
    $blog = $param{Blog}
        if defined $param{Blog};
    if (!$blog && defined $param{BlogID}) {
        my $blog_id = $param{BlogID};
        $blog = MT::Blog->load($blog_id)
          or return $mt->error(
            MT->translate(
                "Load of blog '[_1]' failed: [_2]", $blog_id,
                MT::Blog->errstr
            )
          );
    }
    my $tmpl = $param{Template};
    if ($tmpl && (!$blog || $blog->id != $tmpl->blog_id)) {
        $blog = MT::Blog->load( $tmpl->blog_id );
    }

    return $mt->error(
        MT->translate(
            "Blog, BlogID or Template param must be specified.")
    ) unless $blog;

    return 1 if $blog->is_dynamic;
    my $iter;
    if ($tmpl) {
        my $i = 0;
        $iter = sub { $i++ < 1 ? $tmpl : undef };
    }
    else {
        $iter = MT::Template->load_iter(
            {
                type    => 'index',
                blog_id => $blog->id
            }
        );
    }
    my $force = $param{Force};

    local *FH;

    # Use the offline site path that was previously set for this blog.
    #my $site_root = $blog->site_path;
    my $site_root = get_output_path({ blog_id => $blog->id });


    return $mt->error(
        MT->translate("You did not set your blog publishing path") )
      unless $site_root;
    my $fmgr = $blog->file_mgr;
    while ( my $tmpl = $iter->() ) {
        ## Skip index templates that the user has designated not to be
        ## rebuilt automatically. We need to do the defined-ness check
        ## because we added the flag in 2.01, and for templates saved
        ## before that time, the rebuild_me flag will be undefined. But
        ## we assume that these templates should be rebuilt, since that
        ## was the previous behavior.
        ## Note that dynamic templates do need to be "rebuilt"--the
        ## FileInfo table needs to be maintained.
        if ( !$tmpl->build_dynamic && !$force ) {
            next if ( defined $tmpl->rebuild_me && !$tmpl->rebuild_me );
        }
        next if ( defined $tmpl->build_type && !$tmpl->build_type );

        my $file = $tmpl->outfile;
        $file = '' unless defined $file;
        if ( $tmpl->build_dynamic && ( $file eq '' ) ) {
            next;
        }
        return $mt->error(
            MT->translate(
                "Template '[_1]' does not have an Output File.",
                $tmpl->name
            )
        ) unless $file ne '';
        my $url = join( '/', $blog->site_url, $file );
        unless ( File::Spec->file_name_is_absolute($file) ) {
            $file = File::Spec->catfile( $site_root, $file );
        }

        # Everything from here out is identical with rebuild_file
        my ($rel_url) = ( $url =~ m|^(?:[^:]*\:\/\/)?[^/]*(.*)| );
        $rel_url =~ s|//+|/|g;
        ## Untaint. We have to assume that we can trust the user's setting of
        ## the site_path and the template outfile.
        ($file) = $file =~ /(.+)/s;
        my $finfo = $param{FileInfo};  # available for single template calls
        unless ( $finfo ) {
            require MT::FileInfo;
            my @finfos = MT::FileInfo->load(
                {
                    blog_id     => $tmpl->blog_id,
                    template_id => $tmpl->id
                }
            );
            if (   ( scalar @finfos == 1 )
                && ( $finfos[0]->file_path eq $file )
                && ( ( $finfos[0]->url || '' ) eq $rel_url ) )
            {
                $finfo = $finfos[0];
            }
            else {
                foreach (@finfos) { $_->remove(); }
                $finfo = MT::FileInfo->set_info_for_url(
                    $rel_url, $file, 'index',
                    {
                        Blog     => $tmpl->blog_id,
                        Template => $tmpl->id,
                    }
                  )
                  || die "Couldn't create FileInfo because " . MT::FileInfo->errstr;
            }
        }
        if ( $tmpl->build_dynamic ) {
            rename( $file, $file . ".static" );

            ## If the FileInfo is set to static, flip it to virtual.
            if ( !$finfo->virtual ) {
                $finfo->virtual(1);
                $finfo->save();
            }
        }

        next if ( $tmpl->build_dynamic );
        next unless ( $tmpl->build_type );

        ## We're not building dynamically, so if the FileInfo is currently
        ## set as dynamic (virtual), change it to static.
        if ( $finfo && $finfo->virtual ) {
            $finfo->virtual(0);
            $finfo->save();
        }

        my $timer = MT->get_timer;
        if ($timer) {
            $timer->pause_partial;
        }
        local $timer->{elapsed} = 0 if $timer;

        my $ctx = MT::Template::Context->new;
        next
          unless (
            MT->run_callbacks(
                'build_file_filter',
                Context      => $ctx,
                context      => $ctx,
                ArchiveType  => 'index',
                archive_type => 'index',
                Blog         => $blog,
                blog         => $blog,
                FileInfo     => $finfo,
                file_info    => $finfo,
                Template     => $tmpl,
                template     => $tmpl,
                File         => $file,
                file         => $file,
                force        => $force,
            )
          );
        $ctx->stash( 'blog', $blog );

        require MT::Request;
        MT::Request->instance->cache('build_template', $tmpl);

        my $html = $tmpl->build($ctx);
        unless (defined $html) {
            $timer->unpause if $timer;
            return $mt->error( $tmpl->errstr );
        }

        my $orig_html = $html;
        MT->run_callbacks(
            'build_page',
            Context      => $ctx,
            context      => $ctx,
            Blog         => $blog,
            blog         => $blog,
            FileInfo     => $finfo,
            file_info    => $finfo,
            ArchiveType  => 'index',
            archive_type => 'index',
            RawContent   => \$orig_html,
            raw_content  => \$orig_html,
            Content      => \$html,
            content      => \$html,
            BuildResult  => \$orig_html,
            build_result => \$orig_html,
            Template     => $tmpl,
            template     => $tmpl,
            File         => $file,
            file         => $file
        );

        ## First check whether the content is actually changed. If not,
        ## we won't update the published file, so as not to modify the mtime.
        next unless $fmgr->content_is_updated( $file, \$html );

        ## Determine if we need to build directory structure,
        ## and build it if we do. DirUmask determines
        ## directory permissions.
        require File::Spec;
        my $path = dirname($file);
        $path =~ s!/$!!
          unless $path eq '/';    ## OS X doesn't like / at the end in mkdir().
        unless ( $fmgr->exists($path) ) {
            if (! $fmgr->mkpath($path) ) {
                $timer->unpause if $timer;
                return $mt->trans_error( "Error making path '[_1]': [_2]",
                    $path, $fmgr->errstr );
            }
        }

        ## Update the published file.
        my $use_temp_files = !$mt->{NoTempFiles};
        my $temp_file = $use_temp_files ? "$file.new" : $file;
        unless (defined( $fmgr->put_data( $html, $temp_file ) )) {
            $timer->unpause if $timer;
            return $mt->trans_error( "Writing to '[_1]' failed: [_2]",
                $temp_file, $fmgr->errstr );
        }
        if ($use_temp_files) {
            if (!$fmgr->rename( $temp_file, $file )) {
                $timer->unpause if $timer;
                return $mt->trans_error( "Renaming tempfile '[_1]' failed: [_2]",
                    $temp_file, $fmgr->errstr );
            }
        }
        MT->run_callbacks(
            'build_file',
            Context      => $ctx,
            context      => $ctx,
            ArchiveType  => 'index',
            archive_type => 'index',
            FileInfo     => $finfo,
            file_info    => $finfo,
            Blog         => $blog,
            blog         => $blog,
            RawContent   => \$orig_html,
            raw_content  => \$orig_html,
            Content      => \$html,
            content      => \$html,
            BuildResult  => \$orig_html,
            build_result => \$orig_html,
            Template     => $tmpl,
            template     => $tmpl,
            File         => $file,
            file         => $file
        );

        $timer->mark("total:rebuild_indexes[template_id:" . $tmpl->id . ";file:$file]")
            if $timer;
    }
    1;
}


1;

__END__
