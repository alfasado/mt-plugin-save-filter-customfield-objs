package SaveFilterCustomfieldObjs::Callbacks;

use strict;

sub _save_filter {
    my ( $eh, $app ) = @_;
    my $cb = $eh->name;
    my $obj_type;
    if ( $cb =~ /\.(.*$)/ ) {
        $obj_type = $1;
    }
    my $q = $app->param;
    return 1 if !$q->param('customfield_beacon');

    my $blog_id = $q->param('blog_id') || 0;
    $obj_type = 'website'
        if $obj_type eq 'blog' && $app->blog && !$app->blog->is_blog;

    require CustomFields::Field;
    my $iter = CustomFields::Field->load_iter(
        {   $blog_id ? ( blog_id => [ $blog_id, 0 ] ) : (),
            $obj_type eq 'asset'
            ? ( obj_type => $q->param('asset_type') )
            : ( obj_type => $obj_type ),
        }
    );

    my $sanitizer = sub { return $_[0]; };
    unless ( $app->isa('MT::App::CMS') ) {

        # Sanitize if the value is submitted from an app other than CMS
        my $blog = $app->blog;
        require MT::Sanitize;
        my $sanitize_spec = ( $blog && $blog->sanitize_spec )
            || $app->config->GlobalSanitizeSpec;
        $sanitizer = sub {
            return $_[0]
                ? MT::Sanitize->sanitize( $_[0], $sanitize_spec )
                : $_[0];
        };
    }
    my @errors;
    require MT::Asset;
    my $asset_types = MT::Asset->class_labels;
    my %fields;
    while ( my $field = $iter->() ) {
        my $row        = $field->column_values();
        my $field_name = "customfield_" . $row->{basename};
        if ( $row->{type} eq 'datetime' ) {
            my $ts = '';
            if ( $q->param("d_$field_name") || $q->param("t_$field_name") ) {
                my $date = $q->param("d_$field_name");
                $date = '1970-01-01' if $row->{options} eq 'time';
                my $time = $q->param("t_$field_name");
                $time = '00:00:00' if $row->{options} eq 'date';
                my $ao = $date . ' ' . $time;
                unless ( $ao
                    =~ m!^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})(?::(\d{2}))?$!
                    )
                {
                    push @errors, $app->translate(
                            "Invalid date '[_1]'; dates must be in the format YYYY-MM-DD HH:MM:SS.",
                            $ao );
                    #     return $eh->error(
                    #         $app->translate(
                    #             "Invalid date '[_1]'; dates must be in the format YYYY-MM-DD HH:MM:SS.",
                    #             $ao
                    #         )
                    #     );
                }
                my $s = $6 || 0;
                push @errors, $app->translate(
                        "Invalid date '[_1]'; dates should be real dates.",
                        $ao
                    )
                    # return $eh->error(
                    #     $app->translate(
                    #         "Invalid date '[_1]'; dates should be real dates.",
                    #         $ao
                    #     )
                    #     )
                    if (
                       $s > 59
                    || $s < 0
                    || $5 > 59
                    || $5 < 0
                    || $4 > 23
                    || $4 < 0
                    || $2 > 12
                    || $2 < 1
                    || $3 < 1
                    || ( MT::Util::days_in( $2, $1 ) < $3
                        && !MT::Util::leap_day( $0, $1, $2 ) )
                    );
                $ts = sprintf "%04d%02d%02d%02d%02d%02d", $1, $2, $3, $4, $5,
                    $s;
            }
            $q->param( $field_name, $ts );
        }
        elsif (( $row->{type} =~ m/^asset/ )
            || ( exists( $asset_types->{ 'asset.' . $row->{type} } ) ) )
        {
            if ( my $file = $q->param("file_$field_name") )
            {    # see asset-chooser.tmpl for parameter
                $q->param( $field_name, $file );
            }
        }
        elsif ( ( $row->{type} eq 'url' ) && $q->param($field_name) ) {
            my $valid = 1;
            my $value = $q->param($field_name);
            $value = '' unless defined $value;
            if ( $row->{required} ) {
                $valid = MT::Util::is_url($value);
            }
            else {
                if (   ( $value ne '' )
                    && ( $value ne ( $row->{default} || '' ) ) )
                {
                    $valid = MT::Util::is_url($value);
                }
            }
            push @errors, $app->translate(
                    "Please enter valid URL for the URL field: [_1]",
                    $row->{name}
                ) unless $valid;
                #     return $eh->error(
                #         $app->translate(
                #             "Please enter valid URL for the URL field: [_1]",
                #             $row->{name}
                #         )
                #     ) unless $valid;
        }

        if ( $row->{required} ) {
            push @errors, $app->translate(
                     "Please enter some value for required '[_1]' field.",
                     $row->{name}
                 )
                # return $eh->error(
                #     $app->translate(
                #         "Please enter some value for required '[_1]' field.",
                #         $row->{name}
                #     )
                #     )
                if (
                (      $row->{type} eq 'checkbox'
                    # || $row->{type} eq 'select'
                    || ( $row->{type} eq 'radio' )
                )
                && !defined $q->param($field_name)
                )
                || (
                (      $row->{type} ne 'checkbox'
                    # && $row->{type} ne 'select'
                    && ( $row->{type} ne 'radio' )
                )
                && ( !defined $q->param($field_name)
                    || $q->param($field_name) eq '' )
                );
        }

        my $type_def = $app->registry( 'customfield_types', $row->{type} );

        # handle any special field-level validation
        if ( $type_def && ( my $h = $type_def->{validate} ) ) {
            $h = MT->handler_to_coderef($h) unless ref($h);
            if ( ref $h ) {
                my @values     = $q->param($field_name);
                my @new_values = ();
                foreach my $value (@values) {
                    $app->error(undef);
                    $value = $h->($value);
                    if ( my $err = $app->errstr ) {
                        push @errors, $err;
                        # return $eh->error($err);
                    }
                    else {
                        push( @new_values, $value );
                    }
                }
                $q->param( $field_name, @new_values );
            }
        }
        elsif ( $q->param($field_name) ) {

            # Sanitize if the value is submitted from an app other than CMS
            my @values = $q->param($field_name);
            my $new_values;
            foreach my $value (@values) {
                my $sanitized = $sanitizer->($value);
                push( @$new_values, $sanitized );
            }
            $q->param( $field_name,
                ( scalar @$new_values > 1 ? $new_values : $new_values->[0] )
            );
        }
    }
    if ( @errors ) {
        $eh->error( join('',@errors ) );
    }
    1;
}

1;