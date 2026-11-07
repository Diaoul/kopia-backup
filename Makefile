SCRIPTS = kopia-condition kopia-staleness
UNITS = kopia-backup.service kopia-backup.timer \
	kopia-verify.service kopia-verify.timer
USER_UNITS = kopia-staleness.service kopia-staleness.timer

.PHONY: install install-conf uninstall

install:
	install -d $(DESTDIR)/usr/local/bin
	install -d $(DESTDIR)/etc/systemd/system
	install -d $(DESTDIR)/etc/systemd/user
	install -m 755 $(SCRIPTS) $(DESTDIR)/usr/local/bin/
	install -m 644 $(UNITS) $(DESTDIR)/etc/systemd/system/
	install -m 644 $(USER_UNITS) $(DESTDIR)/etc/systemd/user/
	@echo "Run 'systemctl daemon-reload' and 'systemctl --user daemon-reload' to pick up the changes."

install-conf:
	install -d $(DESTDIR)/etc/kopia
	install -m 644 conf/policy.json $(DESTDIR)/etc/kopia/policy.json

uninstall:
	rm -f $(addprefix $(DESTDIR)/usr/local/bin/,$(SCRIPTS))
	rm -f $(addprefix $(DESTDIR)/etc/systemd/system/,$(UNITS))
	rm -f $(addprefix $(DESTDIR)/etc/systemd/user/,$(USER_UNITS))
