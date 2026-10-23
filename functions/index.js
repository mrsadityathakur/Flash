const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

initializeApp();

const db = getFirestore();
const rideIdPattern = /^[A-Za-z0-9_-]{1,128}$/;

exports.acceptRide = onCall({ region: "us-central1" }, async event => {
  const driverUid = event.auth?.uid;
  if (!driverUid) {
    throw new HttpsError("unauthenticated", "Sign in before accepting a ride.");
  }

  const rideId = event.data?.rideId;
  if (typeof rideId !== "string" || !rideIdPattern.test(rideId)) {
    throw new HttpsError("invalid-argument", "A valid ride ID is required.");
  }

  const userRef = db.doc(`users/${driverUid}`);
  const rideRef = db.doc(`rides/${rideId}`);
  const requestRef = db.doc(`rideRequests/${rideId}`);

  return db.runTransaction(async transaction => {
    const [userSnapshot, rideSnapshot, requestSnapshot] = await Promise.all([
      transaction.get(userRef),
      transaction.get(rideRef),
      transaction.get(requestRef)
    ]);

    if (!userSnapshot.exists || userSnapshot.get("role") !== "driver") {
      throw new HttpsError(
        "permission-denied",
        "Switch to driver mode before accepting rides."
      );
    }
    if (!rideSnapshot.exists || !requestSnapshot.exists) {
      throw new HttpsError("not-found", "This ride is no longer available.");
    }

    const ride = rideSnapshot.data();
    const request = requestSnapshot.data();
    if (ride.customerUid !== request.customerUid
        || ride.pickup !== request.pickup
        || ride.destination !== request.destination
        || ride.rideType !== request.rideType
        || ride.status !== request.status) {
      throw new HttpsError(
        "failed-precondition",
        "Ride data is inconsistent and cannot be accepted."
      );
    }
    if (ride.customerUid === driverUid) {
      throw new HttpsError(
        "permission-denied",
        "You cannot accept your own ride."
      );
    }
    if (ride.status !== "requested"
        || request.status !== "requested"
        || ride.driverUid !== null
        || request.driverUid !== null) {
      throw new HttpsError(
        "failed-precondition",
        "Another driver has already accepted this ride."
      );
    }

    const acceptedAt = FieldValue.serverTimestamp();
    transaction.update(rideRef, {
      status: "accepted",
      driverUid,
      driverName: userSnapshot.get("name") || "Driver",
      driverPhone: userSnapshot.get("phone") || "",
      acceptedAt
    });
    transaction.update(requestRef, {
      status: "accepted",
      driverUid,
      acceptedAt
    });

    return { accepted: true, rideId };
  });
});

exports.switchUserRole = onCall({ region: "us-central1" }, async event => {
  const uid = event.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in before switching modes.");
  }

  const role = event.data?.role;
  if (role !== "customer" && role !== "driver") {
    throw new HttpsError(
      "invalid-argument",
      "Choose either customer or driver mode."
    );
  }

  const profileRef = db.doc(`users/${uid}`);
  const activeStatuses = ["requested", "accepted", "arrived", "in_progress"];
  const customerRidesQuery = db.collection("rides")
    .where("customerUid", "==", uid);
  const driverRidesQuery = db.collection("rides")
    .where("driverUid", "==", uid);

  return db.runTransaction(async transaction => {
    const [profileSnapshot, customerRides, driverRides] = await Promise.all([
      transaction.get(profileRef),
      transaction.get(customerRidesQuery),
      transaction.get(driverRidesQuery)
    ]);

    if (!profileSnapshot.exists) {
      throw new HttpsError("not-found", "Your user profile was not found.");
    }
    if (profileSnapshot.get("role") === role) {
      return { role };
    }

    const hasActiveRide = [...customerRides.docs, ...driverRides.docs]
      .some(ride => activeStatuses.includes(ride.get("status")));
    if (hasActiveRide) {
      throw new HttpsError(
        "failed-precondition",
        "Finish or cancel your active ride before switching modes."
      );
    }

    transaction.update(profileRef, { role });
    return { role };
  });
});
