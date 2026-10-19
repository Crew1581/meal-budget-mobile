class Operation {
  const Operation({
    required this.server,
    required this.key,
    required this.snapshot,
    required this.installationId,
    required this.firstSentAt,
    this.retryUntil,
    this.jobId,
    this.phase = 'unknown',
    this.errorCode,
    this.nextAttemptAt,
  });

  final String server;
  final String key;
  final String snapshot;
  final String installationId;
  final DateTime firstSentAt;
  final DateTime? retryUntil;
  final String? jobId;
  final String phase;
  final String? errorCode;
  final DateTime? nextAttemptAt;

  bool get terminal => ['completed', 'failed', 'missing'].contains(phase);
  bool canReplay(DateTime now) =>
      jobId == null &&
      !terminal &&
      !now.isBefore(firstSentAt) &&
      retryUntil != null &&
      now.isBefore(retryUntil!);

  Operation copy({
    String? jobId,
    String? phase,
    String? errorCode,
    DateTime? nextAttemptAt,
  }) => Operation(
    server: server,
    key: key,
    snapshot: snapshot,
    installationId: installationId,
    firstSentAt: firstSentAt,
    retryUntil: retryUntil,
    jobId: jobId ?? this.jobId,
    phase: phase ?? this.phase,
    errorCode: errorCode ?? this.errorCode,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
  );

  Map<String, Object?> toRow() => {
    'server': server,
    'operation_key': key,
    'snapshot': snapshot,
    'installation_id': installationId,
    'first_sent_at': firstSentAt.toIso8601String(),
    'retry_until': retryUntil?.toIso8601String(),
    'job_id': jobId,
    'phase': phase,
    'error_code': errorCode,
    'next_attempt_at': nextAttemptAt?.toIso8601String(),
  };

  factory Operation.fromRow(Map<String, Object?> row) => Operation(
    server: row['server'] as String,
    key: row['operation_key'] as String,
    snapshot: row['snapshot'] as String,
    installationId: row['installation_id'] as String,
    firstSentAt: DateTime.parse(row['first_sent_at'] as String),
    retryUntil: row['retry_until'] == null
        ? null
        : DateTime.parse(row['retry_until'] as String),
    jobId: row['job_id'] as String?,
    phase: row['phase'] as String,
    errorCode: row['error_code'] as String?,
    nextAttemptAt: row['next_attempt_at'] == null
        ? null
        : DateTime.parse(row['next_attempt_at'] as String),
  );
}
