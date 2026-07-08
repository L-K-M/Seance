/// Séance shared protocol: domain models, end-to-end vault crypto, the synced
/// record envelope, conflict resolution, and sync request/response DTOs.
///
/// This package is depended on verbatim by both the client (`seance_core`) and
/// the sync server (`seance_sync_server`) so the two can never disagree about
/// the wire format or how conflicts resolve.
library;

export 'src/version.dart';

export 'src/crypto/random.dart';
export 'src/crypto/vault.dart';
export 'src/crypto/recovery_key.dart';

export 'src/models/server_config.dart';
export 'src/models/secret.dart';
export 'src/models/host_key.dart';
export 'src/models/snippet.dart';

export 'src/records/record.dart';
export 'src/records/record_codec.dart';
export 'src/records/lww.dart';

export 'src/sync/dtos.dart';
