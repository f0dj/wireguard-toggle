'use strict';
'require view';
'require fs';
'require ui';

function parseKeyVals(text) {
	var out = {};

	(text || '').split('\n').forEach(function (line) {
		var i = line.indexOf('=');

		if (i > 0)
			out[line.slice(0, i)] = line.slice(i + 1);
	});

	return out;
}

function parseProfiles(text) {
	var out = [];

	(text || '').trim().split('\n').forEach(function (line) {
		if (!line)
			return;

		var f = line.split('\t');

		if (f.length < 5)
			return;

		out.push({
			name: f[0],
			endpoint: f[1],
			address: f[2],
			dns: f[3],
			active: f[4] === '1'
		});
	});

	return out;
}

function sanitizeName(name) {
	return (name || '').trim()
		.replace(/\.conf$/i, '')
		.replace(/[^A-Za-z0-9._-]/g, '_')
		.replace(/^\.+/, '')
		.slice(0, 64);
}

function fmtBytes(n) {
	n = parseInt(n, 10) || 0;

	var u = [ 'B', 'KiB', 'MiB', 'GiB' ], i = 0;

	while (n >= 1024 && i < u.length - 1) {
		n /= 1024;
		i++;
	}

	return (i === 0 ? n : n.toFixed(1)) + ' ' + u[i];
}

function fmtAge(s) {
	s = parseInt(s, 10);

	if (isNaN(s) || s < 0)
		return _('never');
	if (s < 60)
		return s + ' ' + _('s');
	if (s < 3600)
		return Math.floor(s / 60) + ' ' + _('min');

	return Math.floor(s / 3600) + ' ' + _('h');
}

return view.extend({
	load: function () {
		return this.fetchAll();
	},

	fetchInfo: function () {
		var self = this;

		return fs.exec('/usr/sbin/vpn-toggle', [ 'info' ]).then(function (res) {
			self.info = parseKeyVals(res.stdout || '');
		}).catch(function () {
			self.info = {};
		});
	},

	fetchProfiles: function () {
		var self = this;

		return fs.exec('/usr/sbin/vpn-toggle', [ 'list' ]).then(function (res) {
			self.profiles = parseProfiles(res.stdout || '');
			self.profilesError = null;
		}).catch(function (err) {
			self.profiles = [];
			self.profilesError = (err.message || String(err));
		});
	},

	fetchAll: function () {
		return Promise.all([ this.fetchInfo(), this.fetchProfiles() ]);
	},

	setBusy: function (busy) {
		document.querySelectorAll('.vpntoggle-action')
			.forEach(function (btn) { btn.disabled = busy; });
	},

	selectedName: function () {
		var el = document.querySelector('input[name="vpntoggle-profile"]:checked');

		return el ? el.value : '';
	},

	refreshDashboard: function () {
		var info = this.info || {},
		    state = info.state || 'UNKNOWN',
		    badge = document.getElementById('vpntoggle-badge'),
		    cls = 'label';

		if (state == 'ON')
			cls += ' label-success';
		else if (state == 'OFF')
			cls += ' label-danger';
		else
			cls += ' label-warning';

		if (badge) {
			badge.className = cls;
			badge.textContent = state == 'ON' ? _('VPN active') :
			                    state == 'OFF' ? _('VPN off') : _('Unknown');
		}

		var fields = {
			'vpntoggle-d-profile': info.profile || '—',
			'vpntoggle-d-endpoint': info.endpoint || '—',
			'vpntoggle-d-handshake': info.handshake != null ? fmtAge(info.handshake) : '—',
			'vpntoggle-d-transfer': fmtBytes(info.rx) + ' ↓ / ' + fmtBytes(info.tx) + ' ↑',
			'vpntoggle-d-rule': info.rule == 'present' ? _('present') : _('missing'),
			'vpntoggle-d-mode': info.mode == 'pinned' ? _('pinned') : _('random')
		};

		Object.keys(fields).forEach(function (id) {
			var node = document.getElementById(id);

			if (node)
				node.textContent = fields[id];
		});
	},

	refreshSettings: function () {
		var info = this.info || {};

		var ks = document.getElementById('vpntoggle-killswitch'),
		    v6 = document.getElementById('vpntoggle-block-ipv6');

		if (ks)
			ks.checked = info.killswitch == '1';
		if (v6)
			v6.checked = info.block_ipv6 == '1';
	},

	refreshProfileList: function () {
		var self = this,
		    tbody = document.getElementById('vpntoggle-profiles-body'),
		    chosen = this.selectedName(),
		    hasActive = (this.profiles || []).some(function (p) { return p.active; });

		if (!tbody)
			return;

		tbody.replaceChildren();

		(this.profiles || []).forEach(function (p, i) {
			tbody.appendChild(E('tr', {}, [
				E('td', {}, [
					E('input', {
						'type': 'radio',
						'name': 'vpntoggle-profile',
						'value': p.name,
						'checked': (p.active || p.name == chosen || (!hasActive && !chosen && i === 0)) ? 'checked' : null
					})
				]),
				E('td', {}, [ p.name ]),
				E('td', {}, [ p.endpoint ]),
				E('td', {}, [ p.address ]),
				E('td', { 'id': 'vpntoggle-lat-' + i }, [ self.latency && self.latency[p.name] || '—' ]),
				E('td', {}, [ p.active ? E('span', { 'class': 'label label-success' }, [ _('active') ]) : '' ])
			]));
		});
	},

	refreshView: function () {
		this.refreshDashboard();
		this.refreshSettings();
		this.refreshProfileList();
	},

	handleAction: function (action, ev) {
		var self = this;

		this.setBusy(true);

		return fs.exec('/usr/sbin/vpn-toggle', [ action ]).then(function (res) {
			if (res.code != 0)
				throw new Error(((res.stderr || '').trim() || _('Command failed')));

			return self.fetchAll();
		}).then(function () {
			self.refreshView();
			ui.addNotification(null, E('p', _('VPN %s completed.').format(action)), 'info');
		}).catch(function (err) {
			ui.addNotification(null, E('p', _('Failed to %s the VPN: %s').format(action, err.message)));
		}).finally(function () {
			self.setBusy(false);
		});
	},

	handlePick: function (ev) {
		var self = this,
		    name = this.selectedName();

		if (!name) {
			ui.addNotification(null, E('p', _('No profile selected.')));
			return;
		}

		this.setBusy(true);

		return fs.exec('/usr/sbin/vpn-toggle', [ 'pick', name ]).then(function (res) {
			if (res.code != 0)
				throw new Error(((res.stderr || '').trim() || _('Command failed')));

			return self.fetchAll();
		}).then(function () {
			self.refreshView();
			ui.addNotification(null, E('p', _('Connected to %s.').format(name)), 'info');
		}).catch(function (err) {
			ui.addNotification(null, E('p', _('Failed to connect to %s: %s').format(name, err.message)));
		}).finally(function () {
			self.setBusy(false);
		});
	},

	handleDelete: function (ev) {
		var self = this,
		    name = this.selectedName();

		if (!name) {
			ui.addNotification(null, E('p', _('No profile selected.')));
			return;
		}

		if (!confirm(_('Delete profile %s?').format(name)))
			return;

		this.setBusy(true);

		return fs.remove('/etc/wireguard/profiles/' + name).then(function () {
			return self.fetchAll();
		}).then(function () {
			self.refreshView();
			ui.addNotification(null, E('p', _('Deleted %s.').format(name)), 'info');
		}).catch(function (err) {
			ui.addNotification(null, E('p', _('Failed to delete %s: %s').format(name, err.message)));
		}).finally(function () {
			self.setBusy(false);
		});
	},

	handleTestLatency: function (ev) {
		var self = this;

		this.latency = this.latency || {};
		this.setBusy(true);

		var chain = Promise.resolve();

		(this.profiles || []).forEach(function (p, i) {
			chain = chain.then(function () {
				return fs.exec('/usr/sbin/vpn-toggle', [ 'latency', p.name ]).then(function (res) {
					var t = (res.stdout || '').trim().replace(/^latency=/, '');

					self.latency[p.name] = (t && t != '-') ? t + ' ' + _('ms') : '—';

					var cell = document.getElementById('vpntoggle-lat-' + i);

					if (cell)
						cell.textContent = self.latency[p.name];
				}).catch(function () {});
			});
		});

		return chain.finally(function () {
			self.setBusy(false);
		});
	},

	handleFileChosen: function (ev) {
		var self = this,
		    file = ev.target.files && ev.target.files[0];

		if (!file)
			return;

		var reader = new FileReader();

		reader.onload = function () {
			self.uploadContent = String(reader.result);

			var nameField = document.getElementById('vpntoggle-name');

			if (nameField && !nameField.value)
				nameField.value = sanitizeName(file.name);

			var info = document.getElementById('vpntoggle-fileinfo');

			if (info)
				info.textContent = file.name + ' (' + file.size + ' B)';
		};

		reader.readAsText(file);
	},

	writeProfile: function (name, content, successMsg) {
		var self = this;

		name = sanitizeName(name);

		if (!content) {
			ui.addNotification(null, E('p', _('No configuration content provided.')));
			return Promise.resolve();
		}

		if (!name) {
			ui.addNotification(null, E('p', _('Please enter a profile name.')));
			return Promise.resolve();
		}

		if (content.indexOf('[Interface]') < 0 || content.indexOf('[Peer]') < 0) {
			ui.addNotification(null, E('p', _('Not a WireGuard config: missing [Interface] or [Peer].')));
			return Promise.resolve();
		}

		var path = '/etc/wireguard/profiles/' + name + '.conf';

		this.setBusy(true);

		return fs.write(path, content, 384).then(function () {
			return fs.exec('/usr/sbin/vpn-toggle', [ 'validate', name ]);
		}).then(function (res) {
			if (res.code != 0) {
				return fs.remove(path).then(function () {
					throw new Error(((res.stderr || '').trim() || _('Profile validation failed')));
				});
			}

			self.uploadContent = null;

			var nameField = document.getElementById('vpntoggle-name'),
			    fileField = document.getElementById('vpntoggle-file'),
			    pasteField = document.getElementById('vpntoggle-paste'),
			    info = document.getElementById('vpntoggle-fileinfo');

			if (nameField) nameField.value = '';
			if (fileField) fileField.value = '';
			if (pasteField) pasteField.value = '';
			if (info) info.textContent = '';

			return self.fetchAll().then(function () {
				self.refreshView();
				ui.addNotification(null, E('p', successMsg), 'info');
			});
		}).catch(function (err) {
			ui.addNotification(null, E('p', _('Import failed: %s').format(err.message)));
		}).finally(function () {
			self.setBusy(false);
		});
	},

	handleUpload: function (ev) {
		var nameField = document.getElementById('vpntoggle-name');

		return this.writeProfile(nameField ? nameField.value : '', this.uploadContent,
			_('Profile uploaded.'));
	},

	handlePaste: function (ev) {
		var nameField = document.getElementById('vpntoggle-name'),
		    pasteField = document.getElementById('vpntoggle-paste');

		return this.writeProfile(nameField ? nameField.value : '',
			pasteField ? pasteField.value : '', _('Profile saved.'));
	},

	handleFetch: function (ev) {
		var self = this,
		    nameField = document.getElementById('vpntoggle-name'),
		    urlField = document.getElementById('vpntoggle-url'),
		    name = sanitizeName(nameField ? nameField.value : ''),
		    url = urlField ? urlField.value.trim() : '';

		if (!name) {
			ui.addNotification(null, E('p', _('Please enter a profile name.')));
			return;
		}

		if (!/^https?:\/\//.test(url)) {
			ui.addNotification(null, E('p', _('Please enter an http(s) URL.')));
			return;
		}

		this.setBusy(true);

		return fs.exec('/usr/sbin/vpn-toggle', [ 'fetch', name, url ]).then(function (res) {
			if (res.code != 0)
				throw new Error(((res.stderr || '').trim() || _('Command failed')));

			if (urlField) urlField.value = '';

			return self.fetchAll().then(function () {
				self.refreshView();
				ui.addNotification(null, E('p', _('Imported %s.').format(name)), 'info');
			});
		}).catch(function (err) {
			ui.addNotification(null, E('p', _('Import failed: %s').format(err.message)));
		}).finally(function () {
			self.setBusy(false);
		});
	},

	handleToggleSetting: function (key, ev) {
		var self = this,
		    val = ev.target.checked ? '1' : '0';

		this.setBusy(true);

		return fs.exec('/usr/sbin/vpn-toggle', [ 'set', key, val ]).then(function (res) {
			if (res.code != 0)
				throw new Error(((res.stderr || '').trim() || _('Command failed')));

			return self.fetchAll();
		}).then(function () {
			self.refreshView();
			ui.addNotification(null, E('p', _('Setting saved.')), 'info');
		}).catch(function (err) {
			ui.addNotification(null, E('p', _('Failed to save setting: %s').format(err.message)));
		}).finally(function () {
			self.setBusy(false);
		});
	},

	dashboardRow: function (label, id) {
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, label),
			E('div', { 'class': 'cbi-value-field' }, [
				E('span', { 'id': id }, '—')
			])
		]);
	},

	render: function (data) {
		var self = this,
		    info = this.info || {},
		    state = info.state || 'UNKNOWN',
		    cls = 'label',
		    hasActive = (this.profiles || []).some(function (p) { return p.active; }),
		    label;

		this.latency = this.latency || {};

		if (state == 'ON')
			cls += ' label-success';
		else if (state == 'OFF')
			cls += ' label-danger';
		else
			cls += ' label-warning';

		label = state == 'ON' ? _('VPN active') :
		        state == 'OFF' ? _('VPN off') : _('Unknown');

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', _('VPN Toggle')),
			E('p', { 'class': 'cbi-map-descr' },
				_('Routes all LAN traffic through a WireGuard profile. ' +
				  'Toggling on picks a random profile; toggling off restores direct ' +
				  'internet with no leftover DNS or routes.')),

			E('div', { 'class': 'alert-message warning' }, [
				E('strong', _('Failsafe: ')),
				_('after every reboot the router returns to direct internet (VPN off). ' +
				  'The VPN is never re-enabled automatically, so a broken tunnel ' +
				  'cannot leave the network offline.')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action important vpntoggle-action',
						'click': ui.createHandlerFn(this, 'handleAction', 'on')
					}, _('Turn VPN on')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action vpntoggle-action',
						'click': ui.createHandlerFn(this, 'handleAction', 'off')
					}, _('Turn VPN off')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action vpntoggle-action',
						'click': ui.createHandlerFn(this, 'handleAction', 'switch')
					}, _('Switch profile')),
					' ',
					E('button', {
						'class': 'cbi-button vpntoggle-action',
						'click': ui.createHandlerFn(this, function () {
							return self.fetchAll().then(function () { self.refreshView(); });
						})
					}, _('Refresh'))
				]),
				E('p', {}, [
					E('span', { 'id': 'vpntoggle-badge', 'class': cls }, [ label ]),
					' ',
					E('em', _('Current state'))
				]),
				this.dashboardRow(_('Active profile'), 'vpntoggle-d-profile'),
				this.dashboardRow(_('Endpoint'), 'vpntoggle-d-endpoint'),
				this.dashboardRow(_('Last handshake'), 'vpntoggle-d-handshake'),
				this.dashboardRow(_('Transfer (rx/tx)'), 'vpntoggle-d-transfer'),
				this.dashboardRow(_('Policy rule'), 'vpntoggle-d-rule'),
				this.dashboardRow(_('Selection mode'), 'vpntoggle-d-mode')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Servers')),
				E('table', { 'class': 'table' }, [
					E('thead', {}, [
						E('tr', {}, [
							E('th', ' '),
							E('th', _('Profile')),
							E('th', _('Endpoint')),
							E('th', _('Address')),
							E('th', _('Latency')),
							E('th', _('Active'))
						])
					]),
					E('tbody', { 'id': 'vpntoggle-profiles-body' }, (this.profiles || []).map(function (p, i) {
						return E('tr', {}, [
							E('td', {}, [
								E('input', {
									'type': 'radio',
									'name': 'vpntoggle-profile',
									'value': p.name,
									'checked': (p.active || (!hasActive && i === 0)) ? 'checked' : null
								})
							]),
							E('td', {}, [ p.name ]),
							E('td', {}, [ p.endpoint ]),
							E('td', {}, [ p.address ]),
							E('td', { 'id': 'vpntoggle-lat-' + i }, [ self.latency[p.name] || '—' ]),
							E('td', {}, [ p.active ? E('span', { 'class': 'label label-success' }, [ _('active') ]) : '' ])
						]);
					}))
				]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action vpntoggle-action',
						'click': ui.createHandlerFn(this, 'handlePick')
					}, _('Connect to selected')),
					' ',
					E('button', {
						'class': 'cbi-button vpntoggle-action',
						'click': ui.createHandlerFn(this, 'handleTestLatency')
					}, _('Test latency')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-remove vpntoggle-action',
						'click': ui.createHandlerFn(this, 'handleDelete')
					}, _('Delete selected'))
				]),
				this.profilesError ? E('p', { 'class': 'alert-message warning' },
					_('Could not read profiles: %s').format(this.profilesError)) : ''
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Import a WireGuard profile')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Profile name')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'vpntoggle-name',
							'type': 'text',
							'class': 'cbi-input-text',
							'placeholder': 'wg-US-NY-1',
							'maxlength': '64'
						})
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Upload .conf')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'vpntoggle-file',
							'type': 'file',
							'accept': '.conf',
							'change': ui.createHandlerFn(this, 'handleFileChosen')
						}),
						' ',
						E('span', { 'id': 'vpntoggle-fileinfo', 'style': 'margin-left:0.5em;' }),
						' ',
						E('button', {
							'class': 'cbi-button cbi-button-action vpntoggle-action',
							'click': ui.createHandlerFn(this, 'handleUpload')
						}, _('Upload'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Paste config')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('textarea', {
							'id': 'vpntoggle-paste',
							'class': 'cbi-input-textarea',
							'rows': '6',
							'style': 'width:100%; font-family:monospace;',
							'placeholder': '[Interface]\nPrivateKey = ...'
						}),
						E('button', {
							'class': 'cbi-button cbi-button-action vpntoggle-action',
							'click': ui.createHandlerFn(this, 'handlePaste')
						}, _('Save pasted config'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('From URL')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'vpntoggle-url',
							'type': 'text',
							'class': 'cbi-input-text',
							'style': 'width:100%;',
							'placeholder': 'https://example.com/wg.conf'
						}),
						E('button', {
							'class': 'cbi-button cbi-button-action vpntoggle-action',
							'click': ui.createHandlerFn(this, 'handleFetch')
						}, _('Download'))
					])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Leak protection')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Kill switch')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'vpntoggle-killswitch',
							'type': 'checkbox',
							'checked': info.killswitch == '1' ? 'checked' : null,
							'change': ui.createHandlerFn(this, 'handleToggleSetting', 'killswitch')
						}),
						' ',
						E('span', _('While the VPN is on, drop LAN traffic that is not going through the tunnel.'))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Block IPv6')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'vpntoggle-block-ipv6',
							'type': 'checkbox',
							'checked': info.block_ipv6 == '1' ? 'checked' : null,
							'change': ui.createHandlerFn(this, 'handleToggleSetting', 'block_ipv6')
						}),
						' ',
						E('span', _('Drop IPv6 from LAN clients while the VPN is on (the tunnel is IPv4-only, so v6 would leak).'))
					])
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
