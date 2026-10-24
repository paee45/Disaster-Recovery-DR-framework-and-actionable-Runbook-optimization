def owned:
  .DbiResourceId != null and
  (.DbiResourceId == $record.resourceIds[$primary] or .DbiResourceId == $record.resourceIds[$replica]);
def named:
  .DBInstanceIdentifier == $primary or .DBInstanceIdentifier == $replica;
def tagged:
  any(.TagList[]?; (.Key == "dr-run" or .Key == "dr-restore") and .Value == $run);
if (.DBSnapshots | type) != "array" then error("Invalid snapshot inventory") else
  {
    manual: [.DBSnapshots[] | select(owned and .SnapshotType == "manual")],
    automated: [.DBSnapshots[] | select(owned and .SnapshotType == "automated")],
    ambiguous: [.DBSnapshots[] | select((named and (owned | not)) or
      (tagged and (owned | not)))],
    unsupported: [.DBSnapshots[] | select(owned and .SnapshotType != "manual" and .SnapshotType != "automated")]
  }
end