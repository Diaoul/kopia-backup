install:
	install -d $(DESTDIR)/usr/local/bin
	install -d $(DESTDIR)/etc/systemd/system
	install -m 755 kopia-condition $(DESTDIR)/usr/local/bin/kopia-condition
	install -m 755 kopia-policy $(DESTDIR)/usr/local/bin/kopia-policy
	install -m 644 kopia-backup.service $(DESTDIR)/etc/systemd/system/
	install -m 644 kopia-backup.timer $(DESTDIR)/etc/systemd/system/
	install -m 644 kopia-maintenance.service $(DESTDIR)/etc/systemd/system/
	install -m 644 kopia-maintenance.timer $(DESTDIR)/etc/systemd/system/

install-conf:
	install -d $(DESTDIR)/etc/kopia
	install -m 644 conf/excludes $(DESTDIR)/etc/kopia/excludes
