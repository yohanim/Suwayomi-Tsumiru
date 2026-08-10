// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

/// A proxy answering for a dead origin: 502/503/504, plus Cloudflare's
/// origin-down codes. 520/525/526 stay surfaced — the origin is alive but
/// misbehaving there, which the user must see to fix.
///
/// Kept dependency-free so the background download isolate can share the one
/// definition rather than growing its own.
bool isGatewayStatus(int status) =>
    status == 502 ||
    status == 503 ||
    status == 504 ||
    (status >= 521 && status <= 524);
