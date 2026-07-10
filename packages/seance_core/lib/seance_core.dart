/// Platform-agnostic core for Séance, shared unchanged by the Flutter app.
///
/// Re-exports [seance_protocol] so app code has a single import for models,
/// crypto, and these client-side services.
library;

export 'package:seance_protocol/seance_protocol.dart';

export 'src/ssh_config/ssh_config_import.dart';

export 'src/hostkey/tofu.dart';

export 'src/terminal/terminal_engine.dart';
export 'src/terminal/paste_sanitizer.dart';
export 'src/terminal/shell_command.dart';

export 'src/ssh/ssh_session.dart';
export 'src/ssh/remote_file_system.dart'
    show
        RemoteFileType,
        RemoteFileErrorKind,
        RemoteFileException,
        RemoteFileEntry,
        RemoteTransferProgress,
        RemoteTransferCancellation,
        RemoteFileSystem,
        remoteJoin,
        remoteBasename,
        remoteParent;

export 'src/probe/probe_service.dart';

export 'src/store/stores.dart';

export 'src/sync/local_record_store.dart';
export 'src/sync/sync_engine.dart';
export 'src/sync/sync_coordinator.dart';
export 'src/sync/http_sync_client.dart';

export 'src/update/version.dart';
export 'src/update/update_checker.dart';

export 'src/llm/provider.dart';
export 'src/llm/anthropic_provider.dart';
export 'src/llm/openai_provider.dart';
export 'src/llm/search.dart';
export 'src/llm/chat_controller.dart';
export 'src/llm/danger_linter.dart';
export 'src/llm/redaction.dart';
