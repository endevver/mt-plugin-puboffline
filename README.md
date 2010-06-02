This plugin allows for users to publish a site to alternate directory. It will automatically publish the entire site to that directory, as well as all static files, and before writing files to the target directory rewrite all URLs accordingly so that they use the `file://` syntax as opposed to `http://`.

# Usage

To publish a site for offline use, navigate to the List Templates screen. Then click "Publish Offline Version" in the page actions widget on the right hand side.

# Template Tags

The plugin also defines the following template tag: 

    <mt:IsOfflineMode><mt:Else></mt:IsOfflineMode>

This template tag can be used to output templates differently when publishing for offline distribution.

In particular, when outputting Permalinks that end with an index filename, notice that the published URL does not include this. In other words, with a template mapping of `folder-path/page-basename/index.html`, the published file will be at `/folder/page-basename/` and the index.html will be excluded. When publishing for offline use, this will cause the browser to open a folder and display its contents and does _not_ default to displaying `index.html`. The following code remedies the problem, providing the expected URLs for the online version, and functional URLs for the offline version:

    <mt:PagePermalink><mt:IsOfflineMode>/index.html</mt:IsOfflineMode>

Of course, this method can be used for Entry, Category, etc Permalinks, too.

# Release Notes

* The copying of static files cannot follow symlinks. If your mt-static directory utilizes symlinks, please switch to hard links or physically copy the files to the mt-static directory.

# Installation

To install this plugin follow the instructions found here:

http://tinyurl.com/easy-plugin-install

# About Endevver

We design and develop web sites, products and services with a focus on 
simplicity, sound design, ease of use and community. We specialize in 
Movable Type and offer numerous services and packages to help customers 
make the most of this powerful publishing platform.

http://www.endevver.com/

# Support

For help with this plugin please visit http://help.endevver.com

# Copyright

Copyright 2010, Endevver, LLC. All rights reserved.

# License

This plugin is licensed under the same terms as Perl itself.