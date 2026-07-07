/// The wire-protocol version. Sent in every sync request so an old client and
/// a new server (or vice versa) can detect a mismatch instead of corrupting
/// data. Bump only on a breaking change to the record envelope or endpoints.
const int kProtocolVersion = 1;
