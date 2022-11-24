//SPDX-License-Identifier: None
pragma solidity ^0.8.0;

/**
 * @dev Utilities on linear curve.
 *
 * Curve: y = mx + c
 */
library LinearCurve {
    /**
     * @dev Returns x, given y and points
     */
    function getX(
        int256 y,
        int256 x1,
        int256 y1,
        int256 x2,
        int256 y2
    ) internal pure returns (int256) {
        return (y - y1) / _gradient(x1, y1, x2, y2);
    }

    /**
     * @dev Returns y, given x and points
     */
    function getY(
        int256 x,
        int256 x1,
        int256 y1,
        int256 x2,
        int256 y2
    ) internal pure returns (int256) {
        return _gradient(x1, y1, x2, y2) * x + y1;
    }

    /**
     * @dev Returns gradient given points
     */
    function _gradient(
        int256 x1,
        int256 y1,
        int256 x2,
        int256 y2
    ) private pure returns (int256) {
        return (y2 - y1) / (x2 - x1);
    }
}
