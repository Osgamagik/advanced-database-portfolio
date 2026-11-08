// =====================================================================
// Portfolio 4 – MongoDB version of the patient-record document model
// Status: NOT executed in the build environment (no MongoDB available there).
// To produce evidence: run against MongoDB Atlas (free M0 tier) or a local mongod.
//
//   mongoimport --uri "$MONGO_URI" --db carepoint --collection patients \
//               --file patients_sample_500.ndjson
//   mongosh "$MONGO_URI/carepoint" mongo_patient_records.js
//
// Then screenshot the output into ../evidence/ .
// =====================================================================
db = db.getSiblingDB("carepoint");

// ---- 1. Schema validation ($jsonSchema) – mirrors the CHECK on the JSONB table ----------------
db.runCommand({
  collMod: "patients",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["hospital_no", "name", "dob", "encounters"],
      properties: {
        hospital_no: { bsonType: "string", pattern: "^CP[0-9]{8}$" },
        name: { bsonType: "object", required: ["first", "last"] },
        sex: { enum: ["F", "M", "X"] },
        blood_group: { enum: ["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"] },
        allergies: {
          bsonType: "array",
          items: { bsonType: "object", required: ["allergen", "severity"],
                   properties: { severity: { enum: ["MILD", "MODERATE", "SEVERE"] } } }
        },
        encounters: { bsonType: "array", maxItems: 500 }   // bound the embedded array (16 MB document limit)
      }
    }
  },
  validationLevel: "moderate"
});

// ---- 2. Indexes ------------------------------------------------------------------------------
db.patients.createIndex({ hospital_no: 1 }, { unique: true });
db.patients.createIndex({ "allergies.allergen": 1, "allergies.severity": 1 });   // multikey index
db.patients.createIndex({ "encounters.diagnoses": 1 });                           // multikey index
db.patients.createIndex({ "encounters.labs.test": 1, "encounters.labs.flag": 1 });

// ---- 3. Queries equivalent to the JSONB demo -------------------------------------------------
print("Q1 full history (single document read):");
printjson(db.patients.findOne({ hospital_no: "CP00000001" }, { _id: 0, name: 1, allergies: 1, "encounters.date": 1, "encounters.diagnoses": 1 }));

print("Q2 SEVERE penicillin allergy ($elemMatch so both conditions apply to the SAME array element):");
print(db.patients.countDocuments({ allergies: { $elemMatch: { allergen: "Penicillin", severity: "SEVERE" } } }));

print("Q3 explain() – confirm the multikey index is used (look for IXSCAN):");
printjson(db.patients.find({ allergies: { $elemMatch: { allergen: "Penicillin", severity: "SEVERE" } } })
          .explain("executionStats").queryPlanner.winningPlan);

print("Q4 Aggregation pipeline: top diagnoses across all encounters");
db.patients.aggregate([
  { $unwind: "$encounters" },
  { $unwind: "$encounters.diagnoses" },
  { $group: { _id: "$encounters.diagnoses", cases: { $sum: 1 } } },
  { $sort: { cases: -1 } },
  { $limit: 5 }
]).forEach(printjson);

print("Q5 Schema flexibility – add a wearable sub-document to one patient only:");
db.patients.updateOne({ hospital_no: "CP00000001" },
  { $set: { wearable: { device: "SmartWatch X", resting_hr: [62, 64, 61] } } });
print(db.patients.countDocuments({ wearable: { $exists: true } }));

print("Q6 Validation rejects a bad document:");
try {
  db.patients.insertOne({ hospital_no: "BAD", name: { first: "X" } });
} catch (e) { print("  rejected: " + e.message); }
