// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../contracts/libs/LinearCurve.sol";

contract LinearCurveTest is Test {
    int256 constant x1 = 0;
    int256 constant y1 = 100;
    int256 constant x2 = 100;
    int256 constant y2 = 0;

    // Context: Find price at point of time
    // Equation: y = -mx + 100
    function test_GetYWithX() public {
        assertEq(LinearCurve.getY(0, x1, y1, x2, y2), 100);
        assertEq(LinearCurve.getY(25, x1, y1, x2, y2), 75);
        assertEq(LinearCurve.getY(50, x1, y1, x2, y2), 50);
        assertEq(LinearCurve.getY(75, x1, y1, x2, y2), 25);
        assertEq(LinearCurve.getY(100, x1, y1, x2, y2), 0);
        assertEq(LinearCurve.getY(-100, x1, y1, x2, y2), 200);
    }

    // Context: Find time for when certain price is hit
    // Equation: x = (y - 100) / (-m)
    function test_GetXWithY() public {
        assertEq(LinearCurve.getX(0, x1, y1, x2, y2), 100);
        assertEq(LinearCurve.getX(25, x1, y1, x2, y2), 75);
        assertEq(LinearCurve.getX(50, x1, y1, x2, y2), 50);
        assertEq(LinearCurve.getX(75, x1, y1, x2, y2), 25);
        assertEq(LinearCurve.getX(100, x1, y1, x2, y2), 0);
        assertEq(LinearCurve.getX(-100, x1, y1, x2, y2), 200);
    }
}
