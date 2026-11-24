FINDING | CCIPMessagingAdapter | _buildMessage | receiver-rejects-requested-finality — VERIFIED by orchestrator in lib: CCIPReceiver.getCCVsAndFinalityConfig default returns WAIT_FOR_FINALITY_FLAG (CCIPReceiver.sol:78); supportsInterface V2 true; OffRamp._getCCVsFromReceiver:708-722 → _ensureRequestedFinalityAllowed(0x00010000, 0) reverts (FinalityCodec.sol:113-120). OnRamp.sol:570 warns explicitly. Every message fails at execution, re-execution too.
description: The adapter asks CCIP for safe-head finality but accepts only full finality, so CCIP never delivers any message and users lose deposits and withdrawals.
fix: Override `getCCVsAndFinalityConfig` in `CCIPMessagingAdapter` to return `FinalityCodec.WAIT_FOR_SAFE_FLAG` as `allowedFinalityConfig`, or send with `WAIT_FOR_FINALITY_FLAG`.
LEAD | Turnstile | setRoutable | routing-guard-misses-adapter-send → merge into Turnstile._isRoutable routing-guard-misses-role-forwarder
NOTE: Roles.sol TURNSTILE=6; docs table stale.
