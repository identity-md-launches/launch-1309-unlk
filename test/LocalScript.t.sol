// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {LocalDemo} from "../script/LocalDemo.s.sol";
import {UnlkHook} from "../src/UnlkHook.sol";

contract LocalInvoker {
    function invoke(LocalDemo demo) external returns (address) {
        return demo.run();
    }
}

contract LocalScriptTest is Test {
    function testLocalSimulationFunctionDoesNotDependOnCaller() public {
        LocalDemo demo = new LocalDemo();
        LocalInvoker caller = new LocalInvoker();
        UnlkHook hook = UnlkHook(caller.invoke(demo));
        assertTrue(hook.bound());
        assertEq(hook.p(), 2500);
    }

    function testLocalScriptRefusesPublicChainId() public {
        LocalDemo demo = new LocalDemo();
        vm.chainId(11155111);
        vm.expectRevert("local chain only");
        demo.run();
    }
}
