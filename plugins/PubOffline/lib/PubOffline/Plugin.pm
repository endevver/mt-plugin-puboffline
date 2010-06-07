package PubOffline::Plugin;

use strict;
use MT::Util qw( format_ts caturl );

sub load_tasks {
    my $cfg = MT->config;
    return {
        'OfflineBatchCleanUp' => {
            'label' => 'Cleanup Finished Publish Batches',
            'frequency' => 1, #3 * 60,
            'code' => sub { 
                PubOffline::Plugin->task_cleanup; 
            }
        }
    };
}

sub task_cleanup {
    my $this = shift;
    require MT::Util;
    my $mt = MT->instance;
    my @batches = MT->model('offline_batch')->load();
    foreach my $batch (@batches) {
        if (MT->model('ts_job')->exist( { offline_batch_id => $batch->id } )) {
            # do nothing at this time
            # possible future: see how long the job has been on the queue, send warning if it has
            # been on the queue too long
        } else {
            if ($batch->email) {
                MT->log({ 
                    message => "It appears the offline publishing batch with an ID of " .$batch->id. " has finished. Notifying " . $batch->email . " and cleaning up.",
                    class   => "system",
                    blog_id => $batch->blog->id,
                    level   => MT::Log::INFO()
                });
                my $date = format_ts( "%Y-%m-%d", $batch->created_on, $batch->blog, undef );
                require MT::Mail;
                my %head = ( To => $batch->email, Subject => '['.$batch->blog->name.'] Publishing Batch Finished' );
                my $body = "The offline publishing batch you initiated on $date has completed. See for yourself:\n\n" . $batch->blog->site_url . "\n\n";
                MT::Mail->send(\%head, $body)
                    or die MT::Mail->errstr;
            } else {
                MT->log({
                    message => "It appears the offline publishing batch with an ID of " .$batch->id. " has finished. Cleaning up.",
                    class   => "system",
                    blog_id => $batch->blog->id,
                    level   => MT::Log::INFO()
                });
            }
            # TODO - copy static files
            $batch->remove;
        }
    }
}

sub tag_is_offline {
    my ( $ctx, $args, $cond ) = @_;
    my $bool = $ctx->stash('__offline_mode');
    return $bool ? 1 : 0;
}

#sub send_blogs_to_queue {
#    my $app = shift;
#    my ($param) = @_;
#    my $q       = $app->{query};
#    $param ||= {};
#    if ( $q->param('create_job') ) {
#        my @blog_ids = split(/,/, $q->param('blog_ids') );
#        foreach my $blog_id (@blog_ids) {
#            _create_batch( $blog_id, $q->param('email') );
#        }
#        return $app->load_tmpl( 'dialog/close.tmpl' );
#    }
#    $param->{blog_ids}       = join( ',', $q->param('id') );
#    $param->{default_email} = $app->user->email;
#    return $app->load_tmpl( 'dialog/send_to_queue.tmpl', $param );
#}

sub send_to_queue {
    my $app = shift;
    my ($param) = @_;
    my $q       = $app->{query};
    $param ||= {};

    return unless $app->blog;

    if ($q->param('create_job')) {
        if (!-e $q->param('file_path') || !-d $q->param('file_path')) {
            $param->{path_nonexist} = 1;
        } elsif (!-w $q->param('file_path')) {
            $param->{path_unwritable} = 1;
        } else {
            _create_batch( $app->blog->id, $q->param('email'), $q->param('file_path') );
            return $app->load_tmpl( 'dialog/close.tmpl' );
        }
    }
    $param->{file_path}     = $q->param('file_path') || '';
    $param->{batch_exists}  = MT->model('offline_batch')->exist({ blog_id => $app->blog->id });
    $param->{blog_id}       = $app->blog->id;
    $param->{default_email} = $app->user->email;
    return $app->load_tmpl( 'dialog/send_to_queue.tmpl', $param );
}

sub _create_batch {
    my ($blog_id, $email, $path) = @_;
    my $app = MT->instance;

    # Skip this blog if it's already marked to republish.
    return if ( MT->model('offline_batch')->exist({ blog_id => $blog_id }) );

    my $batch = MT->model('offline_batch')->new;
    $batch->blog_id( $blog_id );
    $batch->email( $email );
    $batch->path( $path );
    $batch->save
        or return $app->error(
            $app->translate(
                "Unable to create a offline publishing batch and send content to the publish queue",
                $batch->errstr
            )
        );

    require MT::Request;
    my $r = MT::Request->instance();
    $r->stash('offline_batch',$batch);

    require MT::WeblogPublisher;
    my $pub = MT::WeblogPublisher->new;
    $pub->rebuild( BlogID => $blog_id );
    _create_copy_static_job( $batch );
    
    # Save the "real" blog site path so that it can be used later to copy the assets.
    use MT::Session;
    my $session = MT::Session->new;
    $session->id('PubOffline blog '.$blog_id);
    $session->kind('po');
    my $blog = MT->model('blog')->load($blog_id);
    $session->data( $blog->site_path );
    $session->start(time());
    $session->save;
    _create_copy_asset_job( $batch );
}

# This is invoked just before the file is written. We use this to re-write all URLs
# to map http://... to file://...
sub build_page {
    my ( $cb, %args ) = @_;
    my $fi = $args{'file_info'};
    if ($fi->{'offline_batch'}) {
        # Time to override the Blog's site path to the user specified site path
        my $batch   = $fi->{'offline_batch'};
        my $target  = $batch->path;
        #$target = $target . '/' if $target !~ /\/$/;
        my $pattern = $fi->{'__original_site_url'};
        my $replace = caturl("file:\/\/\/",$target);
        my $content = $args{'Content'};
        $$content =~ s/$pattern/$replace/mg;

        # Add index.html to the end of bare URLs
        $$content =~ s/(file:\/\/\/.*)\/(['"])/$1\/index.htm$2/mg;

        require MT::Template::ContextHandlers;
        my $static_pattern = MT::Template::Context::_hdlr_static_path( $args{'Context'} );
        my $static_replace = caturl($replace,'static') . '/';
        $$content =~ s/$static_pattern/$static_replace/mg;
    }
}

# Adds every non-disabled template to the publish queue. 
# This is a near copy of the build_file_filter in MT::WeblogPublisher
sub build_file_filter {
    my ( $cb, %args ) = @_;
    my $fi = $args{'file_info'};

    # Prevents requeuing. In other words it tells the Worker making a call to
    # this filter that the decision to publish this file via the publish queue
    # has already been made. Therefore we need to short circuit this callback.
    # This is our opportunity therefore to modify the template context before
    # returning!
    if ($fi->{'offline_batch'}) {
        # Time to override the Blog's site path to the user specified site path
        my $batch = $fi->{'offline_batch'};
        my $url   = $args{'Blog'}->site_url;
        $args{'file_info'}->{'__original_site_url'} = $url;
        $args{'Blog'}->site_path($batch->path);
        $args{'Context'}->stash('__offline_mode',1);
        # Return 1 and tell MT to physically publish the file!
        return 1;
    }

    # We are obviously not coming from the MT::Worker::PublishOffline 
    # task. We know this of course because $fi->{offline_batch} will
    # be set otherwise.
    require MT::Request;
    my $r = MT::Request->instance();
    my $batch = $r->stash('offline_batch');
    unless ($batch) {
        # Batch does not exist, so assume we can publish. Let other 
        # build_file_filters determine course of action.
        return 1;
    }

    require MT::PublishOption;
    my $throttle = MT::PublishOption::get_throttle($fi);

    # Prevent building of disabled templates if they get this far
    return 0 if $throttle->{type} == MT::PublishOption::DISABLED();

    _create_publish_job( $fi, $batch );
    return 0;
}

sub _create_publish_job {
    my ($fi,$batch) = @_;

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $priority = _get_job_priority($fi);
    my $func_id = $ts->funcname_to_id($ts->driver_for,
                                      $ts->shuffled_databases,
                                      'MT::Worker::PublishOffline');
    my $job = MT->model('ts_job')->new();
    $job->funcid( $func_id );
    $job->uniqkey( $fi->id );
    $job->offline_batch_id( $batch->id );
    $job->priority( $priority );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( ( $fi->blog_id || 0 ) . ':' . $$ . ':' . $priority . ':' . ( time - ( time % 10 ) ) );
    $job->save or MT->log({
        blog_id => $fi->blog_id,
        message => "Could not queue offline publish job: " . $job->errstr
    });
}

sub _create_copy_static_job {
    my ($batch) = @_;

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $func_id = $ts->funcname_to_id($ts->driver_for,
                                      $ts->shuffled_databases,
                                      'MT::Worker::CopyStaticOffline');
    my $job = MT->model('ts_job')->new();
    $job->funcid( $func_id );
    $job->uniqkey( $batch->id );
    $job->offline_batch_id( $batch->id );
    $job->priority( 9 );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( ( $batch->blog_id || 0 ) . ':' . $$ . ':' . 9 . ':' . ( time - ( time % 10 ) ) );
    $job->save or MT->log({
        blog_id => $batch->blog_id,
        message => "Could not queue copy static job: " . $job->errstr
    });
}

sub _create_copy_asset_job {
    my ($batch) = @_;

    # Ok, let's build the Schwartz Job.
    require MT::TheSchwartz;
    my $ts = MT::TheSchwartz->instance();
    my $func_id = $ts->funcname_to_id($ts->driver_for,
                                      $ts->shuffled_databases,
                                      'MT::Worker::CopyAssetOffline');
    my $job = MT->model('ts_job')->new();
    $job->funcid( $func_id );
    $job->uniqkey( $batch->id );
    $job->offline_batch_id( $batch->id );
    $job->priority( 9 );
    $job->grabbed_until(1);
    $job->run_after(1);
    $job->coalesce( ( $batch->blog_id || 0 ) . ':' . $$ . ':' . 9 . ':' . ( time - ( time % 10 ) ) );
    $job->save or MT->log({
        blog_id => $batch->blog_id,
        message => "Could not queue copy asset job: " . $job->errstr
    });
}

sub _get_job_priority {
    my ($fi) = @_;
    my $priority = 0;
    my $at = $fi->archive_type || '';
    # Default priority assignment....
    if (($at eq 'Individual') || ($at eq 'Page')) {
        require MT::TemplateMap;
        my $map = MT::TemplateMap->load($fi->templatemap_id);
        # Individual/Page archive pages that are the 'permalink' pages
        # should have highest build priority.
        if ($map && $map->is_preferred) {
            $priority = 10;
        } else {
            $priority = 5;
        }
    } elsif ($at eq 'index') {
        # Index pages are second in priority, if they are named 'index'
        # or 'default'
        if ($fi->file_path =~ m!/(index|default|atom|feed)!i) {
            $priority = 9;
        } else {
            $priority = 8;
        }
    } elsif ($at =~ m/Category|Author/) {
        $priority = 1;
    } elsif ($at =~ m/Yearly/) {
        $priority = 1;
    } elsif ($at =~ m/Monthly/) {
        $priority = 2;
    } elsif ($at =~ m/Weekly/) {
        $priority = 3;
    } elsif ($at =~ m/Daily/) {
        $priority = 4;
    }
    return $priority;
}

1;
__END__
