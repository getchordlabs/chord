// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MetricV1Adapter} from "../adapters/MetricV1Adapter.sol";

/// @title ChordMetricV1Adapter — `MetricV1Adapter` (Metric OMM v1 through Metric's SimpleRouter, pool provenance by
///        `factory.isPool`) under the Chord name. Same constructor, same H1 router pin. Metric v1 has one factory and
///        one router address on every chain, so every deployment takes the same three arguments.
///        First deployment: Monad.
contract ChordMetricV1Adapter is MetricV1Adapter {
    constructor(address router_, address metricRouter_, address metricFactory_)
        MetricV1Adapter(router_, metricRouter_, metricFactory_)
    {}
}
