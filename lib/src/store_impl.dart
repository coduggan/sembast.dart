import 'dart:async';
import 'dart:math';

import 'package:sembast/sembast.dart';
import 'package:sembast/src/finder.dart';
import 'package:sembast/src/record_impl.dart';
import 'package:sembast/src/transaction_impl.dart';
import 'package:sembast/src/utils.dart';

import 'database_impl.dart';

class SembastStore implements Store {
  final SembastDatabase database;
  Store get store => this;

  ///
  /// Store name
  ///
  @override
  final String name;

  // for key generation
  int _lastIntKey = 0;

  Map<dynamic, Record> recordMap = Map();
  Map<dynamic, Record> txnRecords;

  // bool get isInTransaction => database.isInTransaction;

  SembastStore(this.database, this.name);

  SembastTransaction get currentTransaction => database.currentTransaction;

  // SembastTransaction get zoneTransaction => database.zoneTransaction;

  Future<T> transaction<T>(FutureOr<T> action(Transaction transaction)) =>
      database.transaction(action);

  ///
  /// return the key
  ///
  Future put(var value, [var key]) {
    return transaction((txn) {
      return txnPut(txn as SembastTransaction, value, key);
    });
  }

  txnPut(SembastTransaction txn, var value, var key) {
    Record record = SembastRecord.copy(this, key, value, false);

    txnPutRecord(txn, record);
    if (database.LOGV) {
      SembastDatabase.logger.fine("${txn} put ${record}");
    }
    return record.key;
  }

  ///
  /// stream all the records
  ///
  @override
  Stream<Record> get records {
    StreamController<Record> ctlr = StreamController();
    // asynchronous feeding
    _feedController(null, ctlr);
    ctlr.close();
    return ctlr.stream;
  }

  _feedController(SembastTransaction txn, StreamController<Record> ctlr) {
    _forEachRecords(txn, null, (Record record) {
      ctlr.add(record);
    });
  }

  ///
  /// stream all the records
  ///
  Stream<Record> txnGetRecordsStream(SembastTransaction transaction) {
    StreamController<Record> ctlr = StreamController();
    _feedController(transaction, ctlr);
    ctlr.close();
    return ctlr.stream;
  }

  _forEachRecords(
      SembastTransaction txn, Filter filter, void action(Record record)) {
// handle record in transaction first
    if (_hasTransactionRecords(txn)) {
      txnRecords.values.forEach((Record record) {
        if (Filter.matchRecord(filter, record)) {
          action(record);
        }
      });
    }

    // then the regular unless already in transaction
    recordMap.values.forEach((Record record) {
      if (_hasTransactionRecords(txn)) {
        if (txnRecords.keys.contains(record.key)) {
          // already handled
          return;
        }
      }
      if (Filter.matchRecord(filter, record)) {
        action(record);
      }
    });
  }

  ///
  /// find the first matching record
  ///
  @override
  Future<Record> findRecord(Finder finder) async {
    return txnFindRecord(null, finder);
  }

  @override
  Future findKey(Finder finder) async => (await findRecord(finder))?.key;

  Future txnFindKey(SembastTransaction txn, Finder finder) async =>
      (await txnFindRecord(txn, finder))?.key;

  Record txnFindRecord(SembastTransaction txn, Finder finder) {
    if ((finder as SembastFinder).limit != 1) {
      finder = (finder as SembastFinder).clone(limit: 1);
    }
    var records = txnFindRecords(txn, finder);
    if (records.isNotEmpty) {
      return records.first;
    }
    return null;
  }

  ///
  /// find all records
  ///
  @override
  Future<List<Record>> findRecords(Finder finder) async {
    return txnFindRecords(null, finder);
  }

  List<Record> txnFindRecords(SembastTransaction txn, Finder finder) {
    List<Record> result;

    var sembastFinder = finder as SembastFinder;
    result = [];

    _forEachRecords(txn, sembastFinder?.filter, (Record record) {
      result.add(record);
    });

    if (finder != null) {
      // sort
      result.sort((Record record1, record2) =>
          (finder as SembastFinder).compare(record1, record2));

      // offset
      if (sembastFinder.offset != null) {
        result = result.sublist(min(sembastFinder.offset, result.length));
      }
      // limit
      if (sembastFinder.limit != null) {
        result = result.sublist(0, min(sembastFinder.limit, result.length));
      }
    }
    return result;
  }

  @override
  Future<List> findKeys(Finder finder) async {
    return txnFindKeys(null, finder);
  }

  Future<List> txnFindKeys(SembastTransaction txn, Finder finder) async {
    var records = await txnFindRecords(txn, finder);
    return records.map((Record record) => record.key).toList();
  }

  ///
  /// return true if it existed before
  ///
  bool setRecordInMemory(Record record) {
    SembastStore store = record.store as SembastStore;
    bool exists = store.recordMap[record.key] != null;
    if (record.deleted) {
      store.recordMap.remove(record.key);
    } else {
      store.recordMap[record.key] = record;
    }
    return exists;
  }

  void loadRecord(Record record) {
    var key = record.key;
    setRecordInMemory(record);
    // update for auto increment
    if (key is int) {
      if (key > _lastIntKey) {
        _lastIntKey = key;
      }
    }
  }

  Record txnPutRecord(SembastTransaction txn, Record record) {
    var sembastRecord = record as SembastRecord;
    assert(record.store == this);

    if (!checkValue(record.value)) {
      throw ArgumentError.value(record.value, null,
          "invalid type ${record.value.runtimeType} for record ${record}");
    }

    // auto-gen key if needed
    if (record.key == null) {
      sembastRecord.key = ++_lastIntKey;
    } else {
      // update last int key in case auto gen is needed again
      var recordKey = record.key;
      if (recordKey is int) {
        int intKey = recordKey;
        if (intKey > _lastIntKey) {
          _lastIntKey = intKey;
        }
      }
    }

    // add to store transaction
    if (txnRecords == null) {
      txnRecords = Map();
    }
    txnRecords[record.key] = record;

    return record;
  }

  Record _getRecord(SembastTransaction txn, var key) {
    var record;

    // look in current transaction
    if (_hasTransactionRecords(txn)) {
      record = txnRecords[key];
    }

    if (record == null) {
      record = recordMap[key];
    }
    if (database.LOGV) {
      SembastDatabase.logger
          .fine("${database.currentTransaction} get ${record} key ${key}");
    }
    return record as Record;
  }

  ///
  /// get a record by key
  ///
  @override
  Future<Record> getRecord(var key) async {
    return txnGetRecord(null, key);
  }

  Record txnGetRecord(SembastTransaction txn, key) {
    Record record = _getRecord(txn, key);
    if (record != null) {
      if (record.deleted) {
        record = null;
      }
    }
    return record;
  }

  ///
  /// Get all records from a list of keys
  ///
  @override
  Future<List<Record>> getRecords(Iterable keys) async {
    return txnGetRecords(null, keys);
  }

  List<Record> txnGetRecords(SembastTransaction txn, Iterable keys) {
    List<Record> records = [];

    for (var key in keys) {
      Record record = _getRecord(txn, key);
      if (record != null) {
        if (!record.deleted) {
          records.add(record);
          ;
        }
      }
    }
    return records;
  }

  ///
  /// get a value from a key
  ///
  @override
  Future get(var key) async {
    return txnGet(null, key);
  }

  dynamic txnGet(SembastTransaction txn, key) {
    Record record = txnGetRecord(txn, key);
    if (record != null) {
      return record.value;
    }
    return null;
  }

  ///
  /// count all records
  ///
  @override
  Future<int> count([Filter filter]) async {
    return txnCount(null, filter);
  }

  int txnCount(SembastTransaction txn, Filter filter) {
    int count = 0;
    _forEachRecords(txn, filter, (Record record) {
      count++;
    });
    return count;
  }

  ///
  /// delete a record by key
  ///
  Future delete(var key) {
    return transaction((txn) {
      return txnDelete(txn as SembastTransaction, key);
    });
  }

  dynamic txnDelete(SembastTransaction txn, var key) {
    Record record = _getRecord(txn, key);
    if (record == null) {
      return null;
    } else {
      // clone to keep the existing as is
      Record clone = (record as SembastRecord).clone();
      (clone as SembastRecord).deleted = true;
      txnPutRecord(txn, clone);
      return key;
    }
  }

  ///
  /// return the list of deleted keys
  ///
  @override
  Future deleteAll(Iterable keys) {
    return transaction((txn) {
      return txnDeleteAll(txn as SembastTransaction, keys);
    });
  }

  List txnDeleteAll(SembastTransaction txn, Iterable keys) {
    List<Record> updates = [];
    List deletedKeys = [];
    for (var key in keys) {
      Record record = _getRecord(txn, key);
      if (record != null) {
        Record clone = (record as SembastRecord).clone();
        (clone as SembastRecord).deleted = true;
        updates.add(clone);
        deletedKeys.add(key);
      }
    }

    if (updates.isNotEmpty) {
      database.txnPutRecords(txn, updates);
    }
    return deletedKeys;
  }

  @override
  Future<bool> containsKey(key) async {
    return txnContainsKey(null, key);
  }

  bool _hasTransactionRecords(SembastTransaction txn) {
    return txn != null && txnRecords != null;
  }

  bool txnContainsKey(SembastTransaction txn, key) {
    if (recordMap.containsKey(key)) {
      return true;
    } else if (_hasTransactionRecords(txn)) {
      return txnRecords.containsKey(key);
    } else {
      return false;
    }
  }

  void rollback() {
    // clear map;
    txnRecords = null;
  }

  ///
  /// debug json
  ///
  Map toJson() {
    Map map = {};
    if (name != null) {
      map["name"] = name;
    }
    if (recordMap != null) {
      map["count"] = recordMap.length;
    }
    return map;
  }

  @override
  String toString() {
    return "${name}";
  }

  ///
  /// delete all records in a store
  ///
  ///
  @override
  Future clear() {
    return transaction((txn) {
      // first delete the one in transaction
      txnClear(txn as SembastTransaction);
    });
  }

  List txnClear(SembastTransaction txn) {
    if (_hasTransactionRecords(txn)) {
      return txnDeleteAll(txn, List.from(txnRecords.keys, growable: false));
    }
    Iterable keys = recordMap.keys;
    return txnDeleteAll(txn, List.from(keys, growable: false));
  }
}