NAME=remote-script-partitioner
VERSION=0.0.1

.PHONY: package

package:
	fpm -s empty -t deb -S udeb\
        --name $(NAME) \
        --version $(VERSION) \
        --architecture all \
        --deb-custom-control debian/control \
        --deb-templates debian/remote-script-partitioner.templates \
        --post-install debian/postinst.sh

udeb: package
	mv $(NAME)_$(VERSION)_all.deb $(NAME)_$(VERSION)_all.udeb
