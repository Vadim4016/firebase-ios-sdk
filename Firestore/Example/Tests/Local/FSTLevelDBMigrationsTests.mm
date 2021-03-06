/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>

#include <memory>
#include <string>
#include <vector>

#import "Firestore/Protos/objc/firestore/local/Target.pbobjc.h"
#import "Firestore/Source/Local/FSTLevelDB.h"
#import "Firestore/Source/Local/FSTLevelDBMigrations.h"
#import "Firestore/Source/Local/FSTLevelDBMutationQueue.h"
#import "Firestore/Source/Local/FSTLevelDBQueryCache.h"

#include "Firestore/core/src/firebase/firestore/local/leveldb_key.h"
#include "Firestore/core/src/firebase/firestore/util/ordered_code.h"
#include "Firestore/core/src/firebase/firestore/util/status.h"
#include "Firestore/core/test/firebase/firestore/testutil/testutil.h"
#include "absl/strings/match.h"
#include "leveldb/db.h"

#import "Firestore/Example/Tests/Local/FSTPersistenceTestHelpers.h"

NS_ASSUME_NONNULL_BEGIN

using firebase::firestore::FirestoreErrorCode;
using firebase::firestore::local::LevelDbDocumentTargetKey;
using firebase::firestore::local::LevelDbMutationKey;
using firebase::firestore::local::LevelDbMutationQueueKey;
using firebase::firestore::local::LevelDbQueryTargetKey;
using firebase::firestore::local::LevelDbTargetDocumentKey;
using firebase::firestore::local::LevelDbTargetKey;
using firebase::firestore::local::LevelDbTransaction;
using firebase::firestore::util::OrderedCode;
using firebase::firestore::testutil::Key;
using leveldb::DB;
using leveldb::Options;
using leveldb::Status;

@interface FSTLevelDBMigrationsTests : XCTestCase
@end

@implementation FSTLevelDBMigrationsTests {
  std::unique_ptr<DB> _db;
}

- (void)setUp {
  Options options;
  options.error_if_exists = true;
  options.create_if_missing = true;

  NSString *dir = [FSTPersistenceTestHelpers levelDBDir];
  DB *db;
  Status status = DB::Open(options, [dir UTF8String], &db);
  XCTAssert(status.ok(), @"Failed to create db: %s", status.ToString().c_str());
  _db.reset(db);
}

- (void)tearDown {
  _db.reset();
}

- (void)testAddsTargetGlobal {
  FSTPBTargetGlobal *metadata = [FSTLevelDBQueryCache readTargetMetadataFromDB:_db.get()];
  XCTAssertNil(metadata, @"Not expecting metadata yet, we should have an empty db");
  [FSTLevelDBMigrations runMigrationsWithDatabase:_db.get()];

  metadata = [FSTLevelDBQueryCache readTargetMetadataFromDB:_db.get()];
  XCTAssertNotNil(metadata, @"Migrations should have added the metadata");
}

- (void)testSetsVersionNumber {
  {
    LevelDbTransaction transaction(_db.get(), "testSetsVersionNumber before");
    FSTLevelDBSchemaVersion initial =
        [FSTLevelDBMigrations schemaVersionWithTransaction:&transaction];
    XCTAssertEqual(0, initial, "No version should be equivalent to 0");
  }

  {
    // Pick an arbitrary high migration number and migrate to it.
    [FSTLevelDBMigrations runMigrationsWithDatabase:_db.get()];

    LevelDbTransaction transaction(_db.get(), "testSetsVersionNumber after");
    FSTLevelDBSchemaVersion actual =
        [FSTLevelDBMigrations schemaVersionWithTransaction:&transaction];
    XCTAssertGreaterThan(actual, 0, @"Expected to migrate to a schema version > 0");
  }
}

#define ASSERT_NOT_FOUND(transaction, key)                \
  do {                                                    \
    std::string unused_result;                            \
    Status status = transaction.Get(key, &unused_result); \
    XCTAssertTrue(status.IsNotFound());                   \
  } while (0)

#define ASSERT_FOUND(transaction, key)                    \
  do {                                                    \
    std::string unused_result;                            \
    Status status = transaction.Get(key, &unused_result); \
    XCTAssertTrue(status.ok());                           \
  } while (0)

- (void)testDropsTheQueryCache {
  std::string userID{"user"};
  FSTBatchID batchID = 1;
  FSTTargetID targetID = 2;

  FSTDocumentKey *key1 = Key("documents/1");
  FSTDocumentKey *key2 = Key("documents/2");

  std::string targetKeys[] = {
      LevelDbTargetKey::Key(targetID),
      LevelDbTargetDocumentKey::Key(targetID, key1),
      LevelDbTargetDocumentKey::Key(targetID, key2),
      LevelDbDocumentTargetKey::Key(key1, targetID),
      LevelDbDocumentTargetKey::Key(key2, targetID),
      LevelDbQueryTargetKey::Key("foo.bar.baz", targetID),
  };

  // Keys that should not be modified by the dropping the query cache
  std::string preservedKeys[] = {
      [self dummyKeyForTable:"targetA"],
      LevelDbMutationQueueKey::Key(userID),
      LevelDbMutationKey::Key(userID, batchID),
  };

  [FSTLevelDBMigrations runMigrationsWithDatabase:_db.get() upToVersion:2];
  {
    // Setup some targets to be counted in the migration.
    LevelDbTransaction transaction(_db.get(), "testDropsTheQueryCache setup");
    for (const std::string &key : targetKeys) {
      transaction.Put(key, "target");
    }
    for (const std::string &key : preservedKeys) {
      transaction.Put(key, "preserved");
    }
    transaction.Commit();
  }

  [FSTLevelDBMigrations runMigrationsWithDatabase:_db.get() upToVersion:3];
  {
    LevelDbTransaction transaction(_db.get(), "testDropsTheQueryCache");
    for (const std::string &key : targetKeys) {
      ASSERT_NOT_FOUND(transaction, key);
    }
    for (const std::string &key : preservedKeys) {
      ASSERT_FOUND(transaction, key);
    }

    FSTPBTargetGlobal *metadata = [FSTLevelDBQueryCache readTargetMetadataFromDB:_db.get()];
    XCTAssertNotNil(metadata, @"Metadata should have been added");
    XCTAssertEqual(metadata.targetCount, 0);
  }
}

- (void)testDropsTheQueryCacheWithThousandsOfEntries {
  [FSTLevelDBMigrations runMigrationsWithDatabase:_db.get() upToVersion:2];
  {
    // Setup some targets to be destroyed.
    LevelDbTransaction transaction(_db.get(), "testDropsTheQueryCacheWithThousandsOfEntries setup");
    for (int i = 0; i < 10000; ++i) {
      transaction.Put(LevelDbTargetKey::Key(i), "");
    }
    transaction.Commit();
  }

  [FSTLevelDBMigrations runMigrationsWithDatabase:_db.get() upToVersion:3];
  {
    LevelDbTransaction transaction(_db.get(), "Verify");
    std::string prefix = LevelDbTargetKey::KeyPrefix();

    auto it = transaction.NewIterator();
    std::vector<std::string> found_keys;
    for (it->Seek(prefix); it->Valid() && absl::StartsWith(it->key(), prefix); it->Next()) {
      found_keys.push_back(std::string{it->key()});
    }

    XCTAssertEqual(found_keys, std::vector<std::string>{});
  }
}

/**
 * Creates the name of a dummy entry to make sure the iteration is correctly bounded.
 */
- (std::string)dummyKeyForTable:(const char *)tableName {
  std::string dummyKey;
  // Magic number that indicates a table name follows. Needed to mimic the prefix to the target
  // table.
  OrderedCode::WriteSignedNumIncreasing(&dummyKey, 5);
  OrderedCode::WriteString(&dummyKey, tableName);
  return dummyKey;
}

@end

NS_ASSUME_NONNULL_END
