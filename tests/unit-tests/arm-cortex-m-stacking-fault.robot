*** Variables ***
${PLATFORM}                         SEPARATOR=\n  """
...                                 cpu: CPU.CortexM @ sysbus
...                                 ${SPACE*4}cpuType: "cortex-m7"
...                                 ${SPACE*4}nvic: nvic
...
...                                 nvic: IRQControllers.NVIC @ sysbus 0xe000e000
...                                 ${SPACE*4}-> cpu@0
...
...                                 memory: Memory.MappedMemory @ sysbus 0x0
...                                 ${SPACE*4}size: 0x4000
...                                 """

${PROGRAM}                          SEPARATOR=\n
...                                 ldr r0, =0xE000ED24
...                                 ldr r1, =0x00010000
...                                 str r1, [r0]
...                                 ldr r0, =0xE000ED98
...                                 movs r1, #0
...                                 str r1, [r0]
...                                 ldr r0, =0xE000ED9C
...                                 ldr r1, =0x3000
...                                 str r1, [r0]
...                                 ldr r0, =0xE000EDA0
...                                 movs r1, #0xB
...                                 str r1, [r0]
...                                 ldr r0, =0xE000ED94
...                                 movs r1, #5
...                                 str r1, [r0]
...                                 dsb
...                                 isb
...                                 ldr r0, =0x3020
...                                 msr psp, r0
...                                 movs r0, #2
...                                 msr control, r0
...                                 isb
...                                 svc #0
...                                 b .

${EXTERNAL_PROGRAM}                 SEPARATOR=\n
...                                 ldr r0, =0xE000ED24
...                                 ldr r1, =0x00010000
...                                 str r1, [r0]
...                                 ldr r0, =0xE000ED98
...                                 movs r1, #0
...                                 str r1, [r0]
...                                 ldr r0, =0xE000ED9C
...                                 ldr r1, =0x3000
...                                 str r1, [r0]
...                                 ldr r0, =0xE000EDA0
...                                 movs r1, #0xB
...                                 str r1, [r0]
...                                 ldr r0, =0xE000ED94
...                                 movs r1, #5
...                                 str r1, [r0]
...                                 dsb
...                                 isb
...                                 ldr r0, =0x3020
...                                 msr psp, r0
...                                 movs r0, #2
...                                 msr control, r0
...                                 isb
...                                 ldr r0, =0xE000E100
...                                 movs r1, #1
...                                 str r1, [r0]
...                                 ldr r0, =0xE000E200
...                                 str r1, [r0]
...                                 b .

*** Test Cases ***
Should Preserve Exception Return On Stacking Fault
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString ${PLATFORM}
    Execute Command                 cpu AssembleBlock 0x1000 "b ."
    Execute Command                 cpu AssembleBlock 0x1800 "b ."
    Execute Command                 cpu AssembleBlock 0x2000 "${PROGRAM}"
    Execute Command                 sysbus WriteDoubleWord 0x10 0x1001
    Execute Command                 sysbus WriteDoubleWord 0x2C 0x1801
    Execute Command                 cpu VectorTableOffset 0x0
    Execute Command                 cpu SP 0x3FF0
    Execute Command                 cpu PC 0x2000

    Execute Command                 cpu Step 30

    ${pc}=                          Execute Command  cpu PC
    ${lr}=                          Execute Command  cpu GetRegister "LR"
    ${xpsr}=                        Execute Command  cpu GetRegister "CPSR"
    ${ipsr}=                        Evaluate  int($xpsr, 0) & 0x1FF
    ${msp}=                         Execute Command  cpu GetRegister "SP"
    ${psp}=                         Execute Command  cpu GetRegister "OtherSP"
    ${cfsr}=                        Execute Command  sysbus ReadDoubleWord 0xE000ED28
    Should Be Equal As Numbers      ${pc}  0x1000
    Should Be Equal As Numbers      ${lr}  0xFFFFFFFD
    Should Be Equal As Numbers      ${ipsr}  4
    Should Be Equal As Numbers      ${msp}  0x3FF0
    Should Be Equal As Numbers      ${psp}  0x3020
    Should Be Equal As Numbers      ${cfsr}  0x10

Should Preserve Overridden External Interrupt
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString ${PLATFORM}
    Execute Command                 cpu AssembleBlock 0x1000 "b ."
    Execute Command                 cpu AssembleBlock 0x1800 "b ."
    Execute Command                 cpu AssembleBlock 0x2000 "${EXTERNAL_PROGRAM}"
    Execute Command                 sysbus WriteDoubleWord 0x10 0x1001
    Execute Command                 sysbus WriteDoubleWord 0x40 0x1801
    Execute Command                 cpu VectorTableOffset 0x0
    Execute Command                 cpu SP 0x3FF0
    Execute Command                 cpu PC 0x2000

    Execute Command                 cpu Step 40

    ${pc}=                          Execute Command  cpu PC
    ${lr}=                          Execute Command  cpu GetRegister "LR"
    ${xpsr}=                        Execute Command  cpu GetRegister "CPSR"
    ${ipsr}=                        Evaluate  int($xpsr, 0) & 0x1FF
    ${msp}=                         Execute Command  cpu GetRegister "SP"
    ${psp}=                         Execute Command  cpu GetRegister "OtherSP"
    ${cfsr}=                        Execute Command  sysbus ReadDoubleWord 0xE000ED28
    ${pending}=                     Execute Command  sysbus ReadDoubleWord 0xE000E200
    Should Be Equal As Numbers      ${pc}  0x1000
    Should Be Equal As Numbers      ${lr}  0xFFFFFFFD
    Should Be Equal As Numbers      ${ipsr}  4
    Should Be Equal As Numbers      ${msp}  0x3FF0
    Should Be Equal As Numbers      ${psp}  0x3020
    Should Be Equal As Numbers      ${cfsr}  0x10
    Should Be Equal As Numbers      ${pending}  1

Should Not Repend Selected Original Interrupt
    Execute Command                 mach create
    Execute Command                 machine LoadPlatformDescriptionFromString ${PLATFORM}
    Execute Command                 cpu AssembleBlock 0x1000 "b ."
    Execute Command                 cpu AssembleBlock 0x1800 "b ."
    Execute Command                 cpu AssembleBlock 0x2000 "${EXTERNAL_PROGRAM}"
    Execute Command                 sysbus WriteDoubleWord 0x10 0x1001
    Execute Command                 sysbus WriteDoubleWord 0x40 0x1801
    # Keep IRQ0 selected by giving the derived MemManage lower priority.
    Execute Command                 sysbus WriteByte 0xE000ED18 0x80
    Execute Command                 cpu VectorTableOffset 0x0
    Execute Command                 cpu SP 0x3FF0
    Execute Command                 cpu PC 0x2000

    Execute Command                 cpu Step 40

    ${pc}=                          Execute Command  cpu PC
    ${lr}=                          Execute Command  cpu GetRegister "LR"
    ${xpsr}=                        Execute Command  cpu GetRegister "CPSR"
    ${ipsr}=                        Evaluate  int($xpsr, 0) & 0x1FF
    ${cfsr}=                        Execute Command  sysbus ReadDoubleWord 0xE000ED28
    ${pending}=                     Execute Command  sysbus ReadDoubleWord 0xE000E200
    ${active}=                      Execute Command  sysbus ReadDoubleWord 0xE000E300
    Should Be Equal As Numbers      ${pc}  0x1800
    Should Be Equal As Numbers      ${lr}  0xFFFFFFFD
    Should Be Equal As Numbers      ${ipsr}  16
    Should Be Equal As Numbers      ${cfsr}  0x10
    Should Be Equal As Numbers      ${pending}  0
    Should Be Equal As Numbers      ${active}  1
