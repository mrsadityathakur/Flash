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

    if (!userSnapshot.exists
        || userSnapshot.get("role") !== "driver"
        || userSnapshot.get("driverStatus") !== "approved") {
      throw new HttpsError(
        "permission-denied",
        "Only approved driver accounts can accept rides."
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

exports.reviewDriverApplication = onCall(
  { region: "us-central1" },
  async event => {
    const reviewerUid = event.auth?.uid;
    if (!reviewerUid) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in before reviewing applications."
      );
    }
    if (event.auth.token.admin !== true) {
      throw new HttpsError(
        "permission-denied",
        "Only a trusted reviewer can approve driver applications."
      );
    }

    const applicantUid = event.data?.applicantUid;
    const decision = event.data?.decision;
    const reason = typeof event.data?.reason === "string"
      ? event.data.reason.trim()
      : "";

    if (typeof applicantUid !== "string"
        || !/^[A-Za-z0-9_-]{1,128}$/.test(applicantUid)
        || !["approved", "rejected"].includes(decision)
        || reason.length > 500) {
      throw new HttpsError("invalid-argument", "Invalid review details.");
    }

    const applicationRef = db.doc(`driverApplications/${applicantUid}`);
    const userRef = db.doc(`users/${applicantUid}`);

    return db.runTransaction(async transaction => {
      const [applicationSnapshot, userSnapshot] = await Promise.all([
        transaction.get(applicationRef),
        transaction.get(userRef)
      ]);

      if (!applicationSnapshot.exists || !userSnapshot.exists) {
        throw new HttpsError("not-found", "Driver application not found.");
      }
      const applicantRole = userSnapshot.get("role");
      if (applicationSnapshot.get("status") !== "pending"
          || (applicantRole !== undefined && applicantRole !== "customer")
          || userSnapshot.get("driverStatus") !== "pending") {
        throw new HttpsError(
          "failed-precondition",
          "This application is no longer pending review."
        );
      }

      const reviewedAt = FieldValue.serverTimestamp();
      const approved = decision === "approved";
      transaction.update(userRef, {
        role: approved ? "driver" : "customer",
        driverStatus: decision,
        driverReviewedAt: reviewedAt
      });
      transaction.update(applicationRef, {
        status: decision,
        reviewerUid,
        reviewedAt,
        reviewReason: reason
      });

      return { applicantUid, status: decision };
    });
  }
);
