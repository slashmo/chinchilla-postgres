//===----------------------------------------------------------------------===//
//
// This source file is part of the Chinchilla open source project
//
// Copyright (c) 2023 Moritz Lang and the Chinchilla project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Chinchilla
import Logging
@preconcurrency import PostgresNIO

public enum PostgresConnectionProvider {
    case shared(PostgresConnection)
    case createNew(configuration: PostgresConnection.Configuration)
}

public actor PostgresMigrationTarget: MigrationTarget {
    private var state = State.disconnected
    private let connectionProvider: PostgresConnectionProvider
    private let logger = Logger(label: String(describing: PostgresMigrationTarget.self))

    public init(connectionProvider: PostgresConnectionProvider) {
        self.connectionProvider = connectionProvider
    }

    public init(connectionConfiguration: PostgresConnection.Configuration) {
        self.init(connectionProvider: .createNew(configuration: connectionConfiguration))
    }

    public func createMigrationsTableIfNeeded() async throws {
        try await withConnection { connection in
            _ = try await connection.query(
                """
                CREATE TABLE IF NOT EXISTS chinchilla (
                    id varchar(14) PRIMARY KEY
                );
                """,
                logger: logger
            )
        }
    }

    public func highestAppliedMigrationID() async throws -> Migration.ID? {
        try await withConnection { connection in
            let rows = try await connection.query(
                "SELECT id FROM chinchilla ORDER BY id DESC LIMIT 1;",
                logger: logger
            )

            for try await rawValue in rows.decode(String.self) {
                return Migration.ID(rawValue: rawValue)!
            }

            return nil
        }
    }

    public func apply(id: Migration.ID, sql: String) async throws {
        try await withConnection { connection in
            _ = try await connection.query("BEGIN;", logger: logger)
            do {
                try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                try await connection.query(
                    "INSERT INTO chinchilla (id) VALUES (\(id.rawValue));",
                    logger: logger
                )
                try await connection.query("COMMIT;", logger: logger)
            } catch {
                try await connection.query("ROLLBACK;", logger: logger)
                throw error
            }
        }
    }

    public func rollBack(id: Migration.ID, sql: String) async throws {
        try await withConnection { connection in
            _ = try await connection.query("BEGIN;", logger: logger)
            do {
                try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                try await connection.query("DELETE FROM chinchilla WHERE id = \(id.rawValue);", logger: logger)
                try await connection.query("COMMIT;", logger: logger)
            } catch {
                try await connection.query("ROLLBACK;", logger: logger)
                throw error
            }
        }
    }

    public func shutdown() async throws {
        guard case .createNew = connectionProvider, case .connected(let connection) = state else {
            return
        }
        try await connection.close()
        state = .disconnected
    }

    @discardableResult
    private func withConnection<T: Sendable>(
        _ operation: @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        let connection: PostgresConnection
        switch state {
        case .disconnected:
            switch connectionProvider {
            case .shared(let sharedConnection):
                connection = sharedConnection
                state = .connected(sharedConnection)
            case .createNew(let configuration):
                connection = try await PostgresConnection.connect(
                    configuration: configuration,
                    id: 0,
                    logger: logger
                )
                state = .connected(connection)
            }
        case .connected(let existingConnection):
            connection = existingConnection
        }

        do {
            return try await operation(connection)
        } catch {
            if case .createNew = connectionProvider {
                try await connection.close()
                state = .disconnected
            }
            throw error
        }
    }

    private enum State {
        case disconnected
        case connected(PostgresConnection)
    }
}
