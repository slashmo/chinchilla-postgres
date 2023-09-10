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
import ChinchillaPostgres
@testable import Logging
import PostgresNIO
import XCTest

final class PostgresMigrationTargetTests: XCTestCase {
    private var adminConnection: PostgresConnection!
    private var targetConnection: PostgresConnection!
    private var schema: String!
    private var logger: Logger!

    override func setUp() async throws {
        LoggingSystem.bootstrapStreamLogHandler()
        logger = Logger(label: String(describing: Self.self))

        let connectionConfiguration = try PostgresConnection.Configuration.fromEnvironment()
        adminConnection = try await makeAdminConnection(for: connectionConfiguration)
        targetConnection = try await makeTargetConnection(for: connectionConfiguration)

        schema = "test_\(UInt64.random(in: 0 ... 1000))"
        try await createDatabaseSchema()
        try await updateDefaultSchemaForTargetConnection()
    }

    override func tearDown() async throws {
        try await closeTargetConnection()
        try await dropDatabaseSchema()
        try await closeAdminConnection()
    }

    func test_apply_withValidMigrations_performsMigrations() async throws {
        let repository = TestMigrationRepository(migrations: [
            .stub(
                id: .stub(suffix: "1"),
                upSQL: """
                CREATE TABLE users (
                    id UUID PRIMARY KEY,
                    name VARCHAR
                );
                """
            ),
            .stub(
                id: .stub(suffix: "2"),
                upSQL: "ALTER TABLE users ADD COLUMN email VARCHAR;"
            ),
            .stub(
                id: .stub(suffix: "3"),
                upSQL: "ALTER TABLE users DROP COLUMN name;"
            ),
        ])
        let target = PostgresMigrationTarget(connectionProvider: .shared(targetConnection))
        let migrator = Migrator(repository: repository, target: target)

        do {
            try await migrator.apply()
        } catch {
            print(String(reflecting: error))
            throw error
        }

        do {
            let infoRows = try await adminConnection
                .query(
                    """
                    SELECT table_name, column_name
                    FROM information_schema.columns
                    WHERE table_name = 'users'
                    ORDER BY table_name ASC;
                    """,
                    logger: logger
                )
                .collect()

            let columns = try infoRows.map { row in
                let (tableName, columnName) = try row.decode((String, String).self)
                return TableColumn(tableName: tableName, columnName: columnName)
            }
            XCTAssertEqual(columns, [
                TableColumn(tableName: "users", columnName: "id"),
                TableColumn(tableName: "users", columnName: "email"),
            ])
        } catch {
            print(String(reflecting: error))
            throw error
        }

        struct TableColumn: Equatable {
            let tableName: String
            let columnName: String
        }

        try await target.shutdown()
    }

    func test_apply_withValidMigrations_updatesMigrationsTable() async throws {
        let migrationIDs = (1 ... 100).map { Migration.ID.stub(suffix: "\($0)") }
        let repository = TestMigrationRepository(migrations: migrationIDs.map {
            .stub(id: $0, upSQL: "SELECT VERSION();")
        })
        let target = PostgresMigrationTarget(connectionProvider: .shared(targetConnection))
        let migrator = Migrator(repository: repository, target: target)

        try await migrator.apply()

        let migrationRows = try await adminConnection
            .query("SELECT * FROM \(unescaped: schema).chinchilla", logger: logger)
            .collect()

        XCTAssertEqual(try migrationRows.map { try $0.decode(String.self) }, migrationIDs.map(\.rawValue))

        try await target.shutdown()
    }

    func test_apply_subsequentRuns_performsPendingMigrations() async throws {
        let migrationID1 = Migration.ID.stub(suffix: "1")
        let migrationID2 = Migration.ID.stub(suffix: "2")

        let repository = TestMigrationRepository(migrations: [
            .stub(id: .stub(suffix: "1"), upSQL: "SELECT VERSION();"),
        ])
        let target = PostgresMigrationTarget(connectionProvider: .shared(targetConnection))
        let migrator = Migrator(repository: repository, target: target)

        try await migrator.apply()

        let initialMigrationRows = try await adminConnection
            .query("SELECT * FROM \(unescaped: schema).chinchilla", logger: logger)
            .collect()

        XCTAssertEqual(try initialMigrationRows.map { try $0.decode(String.self) }, [migrationID1.rawValue])

        await repository.add(migration: .stub(id: .stub(suffix: "2"), upSQL: "SELECT VERSION();"))
        try await migrator.apply()

        let subsequentMigrationRows = try await adminConnection
            .query("SELECT * FROM \(unescaped: schema).chinchilla", logger: logger)
            .collect()

        XCTAssertEqual(
            try subsequentMigrationRows.map { try $0.decode(String.self) },
            [migrationID1.rawValue, migrationID2.rawValue]
        )

        try await target.shutdown()
    }

    private func makeAdminConnection(
        for configuration: PostgresConnection.Configuration
    ) async throws -> PostgresConnection {
        do {
            return try await PostgresConnection.connect(
                configuration: configuration,
                id: 0,
                logger: logger
            )
        } catch {
            XCTFail("Failed to create admin connection: \(String(reflecting: error))")
            throw error
        }
    }

    private func closeAdminConnection() async throws {
        do {
            try await adminConnection?.close()
        } catch {
            XCTFail("Failed to close admin connection: \(String(reflecting: error))")
            throw error
        }
    }

    private func makeTargetConnection(
        for configuration: PostgresConnection.Configuration
    ) async throws -> PostgresConnection {
        do {
            return try await PostgresConnection.connect(
                configuration: configuration,
                id: 1,
                logger: logger
            )
        } catch {
            XCTFail("Failed to create target connection: \(String(reflecting: error))")
            throw error
        }
    }

    private func closeTargetConnection() async throws {
        do {
            try await targetConnection?.close()
        } catch {
            XCTFail("Failed to close admin connection: \(String(reflecting: error))")
            throw error
        }
    }

    private func createDatabaseSchema() async throws {
        do {
            try await adminConnection.query("CREATE SCHEMA \(unescaped: schema);", logger: logger)
        } catch {
            XCTFail("Failed to create database schema: \(String(reflecting: error))")
            throw error
        }
    }

    private func dropDatabaseSchema() async throws {
        do {
            try await adminConnection?.query("DROP SCHEMA \(unescaped: schema) CASCADE;", logger: logger)
        } catch {
            XCTFail("Failed to drop database schema: \(String(reflecting: error))")
        }
    }

    private func updateDefaultSchemaForTargetConnection() async throws {
        do {
            try await targetConnection?.query("SET SEARCH_PATH = \(unescaped: schema);", logger: logger)
        } catch {
            XCTFail("Failed to set database search path: \(String(reflecting: error))")
            throw error
        }
    }
}

// MARK: - Helpers

extension PostgresConnection.Configuration {
    fileprivate static func fromEnvironment() throws -> PostgresConnection.Configuration {
        let environment = ProcessInfo.processInfo.environment
        let postgresHost = try XCTUnwrap(environment["POSTGRES_HOST"])
        let postgresUser = try XCTUnwrap(environment["POSTGRES_USER"])
        let postgresPassword = try XCTUnwrap(environment["POSTGRES_PASSWORD"])
        let postgresDB = try XCTUnwrap(environment["POSTGRES_DB"])

        return PostgresConnection.Configuration(
            host: postgresHost,
            username: postgresUser,
            password: postgresPassword,
            database: postgresDB,
            tls: .disable
        )
    }
}

extension LoggingSystem {
    fileprivate static func bootstrapStreamLogHandler(logLevel _: Logger.Level = .debug) {
        LoggingSystem.bootstrapInternal { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
    }
}

actor TestMigrationRepository: MigrationRepository {
    var migrations: [Migration]

    init(migrations: [Migration]) {
        self.migrations = migrations
    }

    func add(migration: Migration) {
        migrations.append(migration)
    }

    func migrations() async throws -> [Migration] { migrations }
}

extension Migration {
    fileprivate static func stub(id: Migration.ID, upSQL: String = "", downSQL _: String = "") -> Migration {
        Migration(id: id, upSQL: upSQL, downSQL: upSQL)
    }
}

extension Migration.ID {
    fileprivate static func stub(suffix: String) -> Migration.ID {
        precondition(suffix.count <= Migration.ID.length, "Stub ID suffix must not be longer than the ID length.")
        return Migration.ID(rawValue: suffix.leftPadded(to: Migration.ID.length))!
    }
}

extension String {
    fileprivate func leftPadded(to count: Int) -> String {
        guard count > self.count else { return self }
        return String(repeating: "0", count: count - self.count) + self
    }
}
