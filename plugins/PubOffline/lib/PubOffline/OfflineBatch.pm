package PubOffline::OfflineBatch;

use strict;
use base qw( MT::Object );

__PACKAGE__->install_properties({
    column_defs => {
        id            => 'integer not null auto_increment',
        blog_id       => 'integer not null',
        path          => 'string(255)', 
        email         => 'string(255)', 
        assets_copied => 'integer',
    },
    audit => 1,
    datasource  => 'offline_batch',
    primary_key => 'id',
});

sub blog {
    my ($obj) = @_;
    $obj->cache_property('blog', sub {
        my $blog_id = $obj->blog_id;
        MT->model('blog')->load($blog_id) or
            $obj->error(MT->translate(
                            "Load of blog '[_1]' failed: [_2]", $blog_id, MT->model('blog')->errstr
                            || MT->translate("record does not exist.")));
    });
}

sub class_label {
    MT->translate("Offline Batch");
}

1;
