import 'connection.dart';
import 'connection_address.dart';

enum ConnectionSetupStep { choose, address, cloud, signIn, check, review }

enum ConnectionSetupBack { stay, discard, leave }

/// Immutable setup inputs. Password and header values retain their exact bytes.
class ConnectionSetupDraft {
  const ConnectionSetupDraft({
    required this.address,
    required this.username,
    required this.password,
    required this.name,
    required this.icon,
    required this.access,
  });
  final String address, username, password, name;
  final ConnectionIcon icon;
  final ConnectionSetupAccess access;
  ConnectionSetupDraft copyWith({
    String? address,
    String? username,
    String? password,
    String? name,
    ConnectionIcon? icon,
    ConnectionSetupAccess? access,
  }) => ConnectionSetupDraft(
    address: address ?? this.address,
    username: username ?? this.username,
    password: password ?? this.password,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    access: access ?? this.access,
  );
}

class ConnectionSetupAccess {
  ConnectionSetupAccess({
    this.proxied = false,
    this.chatUrl = '',
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable(headers);
  final bool proxied;
  final String chatUrl;
  final Map<String, String> headers;

  ConnectionSetupAccess resolve(ConnectionSetupAccessInput input) =>
      ConnectionSetupAccess(
        proxied: input.proxied,
        chatUrl: input.separateChat
            ? ConnectionAddress.parse(input.chatAddress).url
            : '',
        headers: input.headerEdits.resolve(headers),
      );
}

/// A modal's captured inputs, with header preservation owned by its typed edit.
class ConnectionSetupAccessInput {
  ConnectionSetupAccessInput({
    required this.proxied,
    required this.separateChat,
    required this.chatAddress,
    required this.headerEdits,
  });
  final bool proxied, separateChat;
  final String chatAddress;
  final GatewayHeaderEdit headerEdits;
}
