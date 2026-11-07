import 'package:flutter/foundation.dart';

import '../models/connection.dart';
import '../models/connection_address.dart';
import '../models/connection_setup.dart';
import 'connection_access.dart';
import 'connection_setup_probe.dart';
import 'dashboard_oauth_session.dart';
import 'hermes_cloud.dart';

/// A snapshot, never the live probe or its mutable status map.
class ConnectionSetupCheck {
  ConnectionSetupCheck(ConnectionSetupProbe probe)
    : statuses = Map.unmodifiable(probe.statuses),
      checking = probe.checking,
      verified = probe.verified,
      preferredProfileLabel = probe.discovery?.serverPreferred.label,
      error = probe.error,
      httpStatus = probe.httpStatus,
      failedStage = probe.failedStage,
      chatEndpointUnsupported = probe.chatEndpointUnsupported,
      checkedAt = probe.checkedAt;
  final Map<ConnectionCheck, ConnectionCheckStatus> statuses;
  final bool checking, verified;
  final bool chatEndpointUnsupported;
  final String? preferredProfileLabel;
  final String? error;
  final int? httpStatus;
  final ConnectionCheck? failedStage;
  final DateTime? checkedAt;
}

class ConnectionSetupState {
  ConnectionSetupState({
    required this.draft,
    required this.step,
    required this.check,
    required this.editing,
    required this.cloudRoute,
    required this.cloudBusy,
    required this.saving,
    required this.leaving,
    required this.discovery,
    required List<CloudOrganization> organizations,
    required this.instance,
    required this.organization,
    required this.alreadySaved,
    required this.cloudError,
    required this.saveError,
    required this.result,
    required this.canAdvance,
    required this.cards,
    required this.chatSocketUrl,
    required this.chatPath,
    required this.unencrypted,
  }) : organizations = List.unmodifiable(organizations);
  final List<ConnectionSetupStep> cards;
  final ConnectionSetupDraft draft;
  final ConnectionSetupStep step;
  final ConnectionSetupCheck check;
  final bool editing,
      cloudRoute,
      cloudBusy,
      saving,
      leaving,
      canAdvance,
      unencrypted;
  final CloudDiscovery? discovery;
  final List<CloudOrganization> organizations;
  final CloudInstance? instance;
  final String? organization, cloudError, saveError;
  final SavedConnection? alreadySaved, result;
  final String chatSocketUrl, chatPath;
}

/// Opaque modal attempt identity. A UI cannot fabricate an opening revision or
/// accidentally apply another setup owner's credential draft.
class ConnectionSetupAccessEdit {
  ConnectionSetupAccessEdit._(this.initial, this._owner, this._revision);
  final ConnectionSetupAccess initial;
  final ConnectionSetupSession _owner;
  final int _revision;
}

/// Route-scoped setup workflow. The probe owns provisional network resources;
/// this owner alone constructs candidates and adopts/retires provisional OAuth.
/// Saved OAuth is borrowed from the connection registry and is never retired here.
class ConnectionSetupSession extends ChangeNotifier {
  ConnectionSetupSession({
    required ConnectionAccess? initialAccess,
    required List<SavedConnection> Function() savedConnections,
    required HermesCloud cloud,
    required ConnectionProbe Function(ConnectionAccess) createProbe,
    required Future<SavedConnection> Function(SavedConnection) onSave,
    required Future<void> Function(ConnectionIcon)? onSaveIcon,
  }) : _initialAccess = initialAccess,
       _saved = savedConnections,
       _onSaveIcon = onSaveIcon,
       _probe = ConnectionSetupProbe(createProbe: createProbe) {
    _cloud = cloud;
    _onSave = onSave;
    if (initialAccess != null && onSaveIcon == null) {
      throw ArgumentError(
        'Existing connection appearance requires its save command.',
      );
    }
    final initial = initialAccess?.connection;
    _cloudRoute = initial?.isCloud ?? false;
    _step = _cloudRoute
        ? ConnectionSetupStep.cloud
        : initial == null
        ? ConnectionSetupStep.choose
        : ConnectionSetupStep.address;
    final address = initial == null
        ? ''
        : SavedConnection.joinBaseUrl(
            '${initial.useHttps ? 'https' : 'http'}://${initial.host}:${initial.dashboardPort}',
            initial.dashboardPrefix ?? '',
          );
    _draft = ConnectionSetupDraft(
      address: address,
      username: initial?.dashboardUsername ?? '',
      password: initial?.dashboardPassword ?? '',
      name: initial?.label ?? '',
      icon: initial?.icon ?? ConnectionIcon.server,
      access: ConnectionSetupAccess(
        proxied: initial?.dashboardProxied ?? false,
        chatUrl: initial?.desktopGatewayUrl ?? '',
        headers: initial?.gatewayHeaders ?? const {},
      ),
    );
    if (_cloudRoute) {
      _organization = initial!.cloudOrganization;
      _instance = CloudInstance(
        id: initial.cloudInstanceId!,
        name: initial.label,
        state: 'unknown',
        dashboardUrl: address,
      );
      _discovery = _freezeDiscovery(CloudDiscovery(instances: [_instance!]));
      _oauth = initialAccess!.dashboardOAuth; // borrowed, not route-owned
    }
    _probe.addListener(_probeChanged);
    _publish(notify: false);
  }

  final ConnectionAccess? _initialAccess;
  final List<SavedConnection> Function() _saved;
  late final HermesCloud _cloud;
  late final Future<SavedConnection> Function(SavedConnection) _onSave;
  final Future<void> Function(ConnectionIcon)? _onSaveIcon;
  final ConnectionSetupProbe _probe;
  late ConnectionSetupDraft _draft;
  late ConnectionSetupStep _step;
  late bool _cloudRoute;
  bool _cloudBusy = false,
      _saving = false,
      _leaving = false,
      _dirty = false,
      _closed = false,
      _ownsOAuth = false;
  DashboardOAuthSession? _oauth;
  CloudDiscovery? _discovery;
  List<CloudOrganization> _organizations = const [];
  CloudInstance? _instance;
  String? _organization, _cloudError, _saveError;
  SavedConnection? _result;
  int _generation = 0, _revision = 0;
  late ConnectionSetupState _value;
  ConnectionSetupState get value => _value;
  bool get _editing => _initialAccess != null;
  bool _cancelling = false;
  bool _owns(int generation) => !_closed && generation == _generation;

  static CloudDiscovery _freezeDiscovery(CloudDiscovery value) =>
      CloudDiscovery(
        instances: List.unmodifiable(value.instances),
        organizations: List.unmodifiable(value.organizations),
        organization: value.organization,
      );
  SavedConnection? get _alreadySaved {
    if (_editing || _instance == null) return null;
    for (final saved in _saved()) {
      if (saved.cloudInstanceId == _instance!.id &&
          saved.cloudOrganization == _organization) {
        return saved;
      }
    }
    return null;
  }

  void _publish({bool notify = true}) {
    if (_closed) return;
    ConnectionAddress? chat;
    try {
      chat = ConnectionAddress.parse(
        _draft.access.chatUrl.isEmpty ? _draft.address : _draft.access.chatUrl,
      );
    } on FormatException {
      /* Incomplete editor input has no network destination yet. */
    }
    _value = ConnectionSetupState(
      draft: _draft,
      step: _step,
      check: ConnectionSetupCheck(_probe),
      editing: _editing,
      cloudRoute: _cloudRoute,
      cloudBusy: _cloudBusy,
      saving: _saving,
      leaving: _leaving,
      discovery: _discovery,
      organizations: _organizations,
      instance: _instance,
      organization: _organization,
      alreadySaved: _alreadySaved,
      cloudError: _cloudError,
      saveError: _saveError,
      result: _result,
      canAdvance:
          !_saving &&
          !_cloudBusy &&
          !_leaving &&
          ((_step != ConnectionSetupStep.signIn &&
                  _step != ConnectionSetupStep.check) ||
              (_probe.verified && !_probe.checking)) &&
          (_step != ConnectionSetupStep.cloud ||
              _discovery == null ||
              (_discovery!.organizations.isNotEmpty
                  ? _organization != null
                  : _instance?.canConnect == true)),
      cards: List.unmodifiable([
        ConnectionSetupStep.address,
        if (validateAddress(_draft.address) == null) ConnectionSetupStep.signIn,
        if (_probe.verified) ConnectionSetupStep.review,
      ]),
      chatSocketUrl: chat?.socketUrl ?? '',
      chatPath: chat?.path ?? '',
      unencrypted: _draft.address.startsWith('http:'),
    );
    if (notify) notifyListeners();
  }

  void _probeChanged() {
    if (_closed) return;
    _publish();
  }

  void continueVerified() {
    if (_closed ||
        !_value.canAdvance ||
        (_step != ConnectionSetupStep.signIn &&
            _step != ConnectionSetupStep.check)) {
      return;
    }
    _go(ConnectionSetupStep.review);
  }

  /// A settled swipe uses the same transitions as Next and Back.
  void selectCard(ConnectionSetupStep target) {
    if (_closed ||
        _saving ||
        _cloudBusy ||
        _leaving ||
        _cloudRoute ||
        !_value.cards.contains(target)) {
      return;
    }
    final current = _value.cards.indexOf(_step);
    final next = _value.cards.indexOf(target);
    if (current < 0 || (next - current).abs() != 1) return;
    if (next < current) {
      back();
    } else if (_step == ConnectionSetupStep.address) {
      continueAddress();
    } else {
      continueVerified();
    }
  }

  void _go(ConnectionSetupStep step) {
    _step = step;
    _saveError = null;
    if (step != ConnectionSetupStep.review) _probe.cancel();
    _publish();
  }

  void _edit(ConnectionSetupDraft draft, {bool invalidatesCheck = true}) {
    if (_closed || _saving || _leaving || _cloudBusy) return;
    _revision++;
    _draft = draft;
    _dirty = true;
    _saveError = null;
    if (invalidatesCheck) {
      _generation++;
      _probe.cancel();
      if (_step == ConnectionSetupStep.check ||
          _step == ConnectionSetupStep.review) {
        _step = _cloudRoute
            ? ConnectionSetupStep.cloud
            : ConnectionSetupStep.signIn;
      }
    }
    _publish();
  }

  void editAddress(String value) => _edit(_draft.copyWith(address: value));
  void editUsername(String value) => _edit(_draft.copyWith(username: value));
  void editPassword(String value) => _edit(_draft.copyWith(password: value));
  void editName(String value) =>
      _edit(_draft.copyWith(name: value), invalidatesCheck: false);
  String? validateAddress(String? value) {
    try {
      ConnectionAddress.parse(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  String? validateUsername(String? value) =>
      value == null || value.trim().isEmpty
      ? 'Enter your dashboard username.'
      : null;
  String? validatePassword(String? value) =>
      value == null || value.isEmpty ? 'Enter your dashboard password.' : null;
  String? validateName(String? value) => value == null || value.trim().isEmpty
      ? 'Give this instance a name.'
      : null;
  bool continueAddress() {
    if (_closed || _saving || validateAddress(_draft.address) != null) {
      return false;
    }
    final address = ConnectionAddress.parse(_draft.address);
    _draft = _draft.copyWith(
      address: address.url,
      name: _draft.name.isEmpty ? address.host : _draft.name,
    );
    _go(ConnectionSetupStep.signIn);
    return true;
  }

  void _dropOAuth() {
    if (_ownsOAuth) _oauth?.retire();
    _oauth = null;
    _ownsOAuth = false;
  }

  void chooseSource({required bool cloud}) {
    if (_closed || _saving || _cloudBusy) return;
    _generation++;
    _revision++;
    if (!cloud) _dropOAuth();
    _cloudRoute = cloud;
    _go(cloud ? ConnectionSetupStep.cloud : ConnectionSetupStep.address);
  }

  ConnectionSetupAccessEdit beginAccessEdit() =>
      ConnectionSetupAccessEdit._(_draft.access, this, _revision);

  bool applyAccess(
    ConnectionSetupAccessInput input, {
    required ConnectionSetupAccessEdit edit,
  }) {
    if (_closed ||
        !identical(edit._owner, this) ||
        edit._revision != _revision ||
        _saving ||
        _cloudBusy) {
      return false;
    }
    _edit(_draft.copyWith(access: _draft.access.resolve(input)));
    _go(ConnectionSetupStep.signIn);
    return true;
  }

  Future<void> setIcon(ConnectionIcon icon) async {
    if (_closed || _saving) return;
    await _onSaveIcon?.call(icon);
    if (_closed) return;
    _draft = _draft.copyWith(icon: icon);
    if (!_editing) _dirty = true;
    _publish();
  }

  void selectOrganization(String? value) {
    if (_closed || _cloudBusy || _saving) return;
    if (_discovery == null ||
        !_discovery!.organizations.any((org) => org.id == value)) {
      return;
    }
    if (_organization != value) _dropOAuth();
    _organization = value;
    _revision++;
    _probe.cancel();
    _publish();
  }

  void selectInstance(String? id) {
    if (_closed || _cloudBusy || _saving || _discovery == null) return;
    final matches = _discovery!.instances.where(
      (value) => value.id == id && value.canConnect,
    );
    if (matches.isEmpty) return;
    if (_instance?.id != id) _dropOAuth();
    _instance = matches.first;
    _cloudError = null;
    _revision++;
    _probe.cancel();
    _publish();
  }

  void changeOrganization() {
    if (_closed || _cloudBusy || _saving || _organizations.length < 2) return;
    _dropOAuth();
    _discovery = _freezeDiscovery(
      CloudDiscovery(organizations: _organizations),
    );
    _organization = null;
    _instance = null;
    _cloudError = null;
    _revision++;
    _probe.cancel();
    _publish();
  }

  Future<void> refreshCloud({bool switchAccount = false}) async {
    if (_closed || _cloudBusy || _saving) return;
    final generation = ++_generation;
    _cloudBusy = true;
    _cloudError = null;
    _probe.cancel();
    if (switchAccount) {
      _discovery = null;
      _instance = null;
      _organization = null;
      _organizations = const [];
      _dropOAuth();
    }
    _publish();
    if (!_owns(generation)) return;
    try {
      final result = await _cloud.discover(
        organization: switchAccount ? null : _organization,
        switchAccount: switchAccount,
      );
      if (!_owns(generation)) return;
      if (result != null) {
        _discovery = _freezeDiscovery(result);
        if (result.organizations.isNotEmpty) {
          _organizations = List.unmodifiable(result.organizations);
        }
        _instance = null;
        _dropOAuth();
        _organization = result.organization?.id;
        _revision++;
      }
    } catch (error) {
      if (_owns(generation)) {
        _cloudError = error is CloudAccessException
            ? error.message
            : 'Couldn’t reach Nous Portal. Try again.';
      }
    } finally {
      if (_owns(generation)) {
        _cloudBusy = false;
        _publish();
      }
    }
  }

  Future<void> continueCloud() async {
    if (_closed || _cloudBusy || _saving) return;
    if (_discovery == null || _discovery!.organizations.isNotEmpty) {
      await refreshCloud();
      return;
    }
    final instance = _instance;
    if (instance?.canConnect != true) return;
    final addressError = validateAddress(instance!.dashboardUrl);
    if (addressError != null) {
      _cloudError = addressError;
      _publish();
      return;
    }
    final saved = _alreadySaved;
    if (saved != null) {
      _leave(saved);
      return;
    }
    // Editing the captured saved destination uses its shared refresh owner.
    if (!_ownsOAuth && _oauth?.isActive == true) {
      await check();
      return;
    }
    final generation = ++_generation;
    _cloudBusy = true;
    _cloudError = null;
    _publish();
    if (!_owns(generation)) return;
    try {
      final session = await _cloud.signIn(instance);
      if (session == null) return;
      if (!_owns(generation)) {
        session.retire();
        return;
      }
      _dropOAuth();
      _oauth = session;
      _ownsOAuth = true;
      _draft = _draft.copyWith(
        address: instance.dashboardUrl!,
        name: _editing ? _draft.name : instance.name,
        access: ConnectionSetupAccess(),
        username: '',
        password: '',
      );
      _dirty = true;
      _revision++;
      _cloudBusy = false;
      _publish();
      await check();
    } catch (error) {
      if (_owns(generation)) {
        _cloudError = error is CloudAccessException
            ? error.message
            : 'Couldn’t sign in to this Hermes. Try again.';
      }
    } finally {
      if (_owns(generation)) {
        _cloudBusy = false;
        _publish();
      }
    }
  }

  void portalOpenFailed() {
    if (_closed) return;
    _cloudError =
        'Couldn’t open Nous Portal. Visit portal.nousresearch.com in your browser.';
    _publish();
  }

  Future<void> check() async {
    if (_closed ||
        _leaving ||
        _saving ||
        _cloudBusy ||
        _probe.checking ||
        validateAddress(_draft.address) != null) {
      return;
    }
    if (!_cloudRoute &&
        !_draft.access.proxied &&
        (validateUsername(_draft.username) != null ||
            validatePassword(_draft.password) != null)) {
      return;
    }
    if (_cloudRoute &&
        (_instance?.canConnect != true || _oauth?.isActive != true)) {
      return;
    }
    final address = ConnectionAddress.parse(_draft.address);
    final candidate = SavedConnection(
      id: _initialAccess?.connection.id ?? 'new-connection',
      label: _draft.name.trim(),
      icon: _draft.icon,
      host: address.host,
      port: address.port,
      useHttps: address.useHttps,
      apiKey: '',
      cloudInstanceId: _cloudRoute ? _instance!.id : null,
      cloudOrganization: _cloudRoute ? _organization : null,
      dashboardGrant: _cloudRoute ? _oauth!.currentGrant : null,
      dashboardPortOverride: address.port,
      dashboardPrefix: address.path,
      dashboardProxied: _draft.access.proxied,
      dashboardUsername: _cloudRoute || _draft.access.proxied
          ? null
          : _draft.username.trim(),
      dashboardPassword: _cloudRoute || _draft.access.proxied
          ? null
          : _draft.password,
      desktopGatewayUrl: _draft.access.chatUrl.isEmpty
          ? null
          : _draft.access.chatUrl,
      gatewayHeaders: _draft.access.headers,
    );
    final generation = _generation;
    if (_cloudRoute) {
      _go(ConnectionSetupStep.check);
    } else {
      _probe.cancel();
      _publish();
    }
    if (!_owns(generation)) return;
    await _probe.check(
      ConnectionAccess(
        connection: candidate,
        dashboardOAuth: _cloudRoute ? _oauth : null,
      ),
    );
  }

  void editSignIn() {
    if (_closed || _saving || _cloudBusy) return;
    _generation++;
    // An explicit failed-check recovery must obtain new authorization. Dropping
    // a borrowed reference never retires the saved registry owner.
    if (_cloudRoute && _probe.error != null) _dropOAuth();
    _go(_cloudRoute ? ConnectionSetupStep.cloud : ConnectionSetupStep.signIn);
  }

  void reviewAddress() {
    if (_closed || _saving || _cloudBusy || _cloudRoute) return;
    _generation++;
    _go(ConnectionSetupStep.address);
  }

  Future<void> save() async {
    if (_closed ||
        _saving ||
        !_probe.verified ||
        validateName(_draft.name) != null) {
      return;
    }
    final generation = _generation;
    SavedConnection candidate;
    try {
      candidate = _probe.verifiedConnection.copyWith(
        label: _draft.name.trim(),
        icon: _draft.icon,
      );
    } on StateError {
      _go(_cloudRoute ? ConnectionSetupStep.cloud : ConnectionSetupStep.signIn);
      if (_cloudRoute) {
        _cloudError = 'Your sign-in changed. Sign in to this Hermes again.';
      }
      _publish();
      return;
    }
    _saving = true;
    _saveError = null;
    _publish();
    if (!_owns(generation)) return;
    try {
      final saved = await _onSave(candidate);
      // The durable registry now owns saved access. Do not keep a second route
      // refresh owner alive through navigation's dismissal animation.
      if (_ownsOAuth) _dropOAuth();
      if (_owns(generation)) _leave(saved);
    } catch (_) {
      if (_owns(generation)) {
        _saving = false;
        _saveError =
            'Couldn’t save this connection on this device. Your details are still here. Try saving again.';
        _publish();
      }
    }
  }

  void _leave([SavedConnection? result]) {
    _leaving = true;
    _result = result;
    _publish();
  }

  Future<ConnectionSetupBack> back() async {
    if (_closed || _saving || _leaving || _cancelling) {
      return ConnectionSetupBack.stay;
    }
    if (_cloudBusy) {
      final generation = ++_generation;
      _cancelling = true;
      try {
        await _cloud.cancel();
      } catch (_) {
        if (_owns(generation)) {
          _cloudError = 'Couldn’t finish cancelling sign-in. Try again.';
        }
      } finally {
        _cancelling = false;
        if (_owns(generation)) {
          _cloudBusy = false;
          _publish();
        }
      }
      return ConnectionSetupBack.stay;
    }
    if (_step == ConnectionSetupStep.review) {
      _step = _cloudRoute
          ? ConnectionSetupStep.check
          : ConnectionSetupStep.signIn;
      _saveError = null;
      _publish();
      return ConnectionSetupBack.stay;
    }
    if (_step == ConnectionSetupStep.check) {
      editSignIn();
      return ConnectionSetupBack.stay;
    }
    if (_step == ConnectionSetupStep.signIn) {
      _go(ConnectionSetupStep.address);
      return ConnectionSetupBack.stay;
    }
    if (!_editing &&
        (_step == ConnectionSetupStep.address ||
            _step == ConnectionSetupStep.cloud)) {
      _generation++;
      _dropOAuth();
      _go(ConnectionSetupStep.choose);
      return ConnectionSetupBack.stay;
    }
    if (_dirty) return ConnectionSetupBack.discard;
    _leave();
    return ConnectionSetupBack.leave;
  }

  void discard() {
    if (!_closed && !_saving && !_leaving) _leave();
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    _dropOAuth();
    _cloud.close();
    _probe.removeListener(_probeChanged);
    _probe.dispose();
    super.dispose();
  }
}
