;backlight_enc.asm V0.5 QRT220218
;
;ATTINY13 - - - - - - - - - - - - - - - - - - - - - - - - - -
;fuse bits     43210   high
;SELFPRGEN     1||||   (default off)
;DWEN           1|||   (default off)
;BODLEVEL1..0    11|   (default off) (drains power in sleep mode)
;RSTDISBL          1   (default off)
;              11111
;
;fuse bits  76543210   low
;SPIEN      0|||||||   (default on)
;EESAVE      1||||||   (default off)
;WDTON        1|||||   (default off) (watchdog force system reset mode)
;CKDIV8        1||||   no clock div during startup
;SUT1..0        10||   64 ms + 14 CK startup (default)
;CKSEL1..0        10   9.6 MHz system clock
;           01111010

;-------------------------------------------------------------------------------

;V0.5   initial version

;-------------------------------------------------------------------------------

;.device ATtiny13
.include "tn13def.inc"

.define PWLOGIC     1                   ;PW logic           0 negative  1 positive
.define ENCDIR      0                   ;encoder direction  0 normal    1 reverse 

;-------------------------------------------------------------------------------

.cseg
.org $0000
rjmp main                                ;Reset Handler
;.org $0001
;rjmp EXT_INT0                           ;External Interrupt0 Handler
;.org $0002
;rjmp PCINT0                             ;Pin Change Interrrupt Handler
;.org $0003
;rjmp TIM0_OVF                           ;Timer0 Overflow Handler
;.org $0004
;rjmp EE_RDY                             ;EEPROM Ready Handler
;.org $0005
;rjmp ANA_COMP                           ;Analog Comparator Handler
;.org $0006
;rjmp TIM0_COMPA                         ;Timer0 Compare A
;.org $0007
;rjmp TIM0_COMPB                         ;Timer0 CompareB Handler
;.org $0008
;rjmp WATCHDOG                           ;Watchdog Interrupt Handler
;.org $0009
;rjmp ADC                                ;ADC Conversion Handler

;-------------------------------------------------------------------------------

.def    a0          =   r0             ;main registers set a
.def    a1          =   r1
.def    a2          =   r2
.def    a3          =   r3
.def    a4          =   r24             ;main registers set a immediate
.def    a5          =   r25
.def    a6          =   r16
.def    a7          =   r17

.def    FLAGR       =   r29             ;flag register          YH
.def    NULR        =   r31             ;NULL value register    ZH

.def    sysTic      =   r4              ;system ticker

.def    encPos      =   r18             ;encoder position
.def    encLast     =   r19             ;                 last
.def    keyCnt      =   r20             ;key counter
.def    pwCnt       =   r21             ;PW 

;-------------------------------------------------------------------------------

.equ    KEYP        =   PORTB           ;key port
.equ    KEYPP       =   PINB            ;    pinport
.equ    KEY         =   PINB3           ;                           in P

.equ    SLEDP       =   PORTB           ;status LED port
.equ    SLEDPP      =   PINB            ;           pinport
.equ    SLED        =   PINB4           ;                           out L

.equ    ENCP        =   PORTB           ;encoder port
.equ    ENCPP       =   PINB            ;
.equ    ENCA        =   PINB1           ;                           in P
.equ    ENCB        =   PINB2           ;                           in P

.equ    PWOUTP      =   PORTB           ;PW out port
.equ    PWOUTPP     =   PINB            ;       pinport
.equ    PWOUT       =   PINB0           ;       (OCA0)              out L/H

.if PWLOGIC == 0
;                         ..-skeep      c sled, k key, e encoder, p pw
;                         ..IOIIIO      I input, O output, . not present, - unused
.equ    DDRBM       =   0b00010001
;                         ..NLPPPH      L low, H high, P pullup, N no pullup
.equ    PORTBM      =   0b00001111

.else
;                         ..-skeep
;                         ..IOIIIO
.equ    DDRBM       =   0b00010001
;                         ..NLPPPL
.equ    PORTBM      =   0b00001110
.endif

;-------------------------------------------------------------------------------

.equ    KEYCYCM   =   0x0f                ;key cycle mask
.equ    KSHORT    =   (50/(KEYCYCM+1))    ;    short time 50 ms
.equ    KLONGT    =   (2000/(KEYCYCM+1))  ;    long        2 s

;-------------------------------------------------------------------------------

encTab:
.DB     0, 0, -1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, -1, 0, 0        ;encoder half resolution
;.DB    0, 1, -1, 0, -1, 0, 0, 1, 1, 0, 0, -1, 0, -1, 1, 0      ;        full

advTab:                                                                 
.DB     16, 1, 32, 2, 64, 4, 128, 8, 255, 16                    ;PW advance

.equ    NUMPW       =   3
.equ    PWSTART     =   1

pwTab:
.DB     0, 64, 255, 0

;-------------------------------------------------------------------------------

main:
        adiw    a5:a4,1

        ldi     a4,low(RAMEND)              ;set stack pointer
        out     SPL,a4                      ;to top of RAM

        ldi     a4,PORTBM                   ;port B
        out     PORTB,a4
        ldi     a4,DDRBM                    ;ddr B
        out     DDRB,a4

        sbi     ACSR,ACD                    ;comparator off

;- - - - - - - - - - - - - - - - - - - -

        clr     NULR                        ;init NULR (ZH)
        ldi     ZL,29                       ;reset registers
        st      Z,NULR                      ;store indirect
        dec     ZL                          ;decrement address
        brpl    PC-2                        ;r0..29 = 0, ZL = $ff, ZH = 0 (NULR)

        ldi     ZL,low(SRAM_START)          ;clear SRAM
        st      Z+,NULR
        cpi     ZL,low(RAMEND)
        brne    PC-2

;- - - - - - - - - - - - - - - - - - - -

        ; ldi     a4,(1<<OCIE0B)     ;enable T0 CMP B
        ; out     TIMSK0,a4

.if PWLOGIC == 0
        ;OCA0 H up L down, pwm phase correct top $ff
        ldi     a4,(1<<COM0A1|1<<COM0A0|1<<WGM00)
.else
        ;OCA0 L up H down, pwm phase correct top $ff
        ldi     a4,(1<<COM0A1|0<<COM0A0|1<<WGM00)
.endif
        out     TCCR0A,a4

;       ldi     a4,(1<<CS00)                ;div  1, 9.6E6 / 510    ~ 18.8 kHz   fpw
;       ldi     a4,(1<<CS01)                ;     8,                ~ 2.4 kHz
;       ldi     a4,(1<<CS01|1<<CS00)        ;    64,                ~ 294 Hz
        ldi     a4,(1<<CS02)                ;   256,                ~ 73 Hz               
        out     TCCR0B,a4                   ;start T0

        ; sei                               ;no IRs used

;- - - - - - - - - - - - - - - - - - - -

        ldi     pwCnt,PWSTART               ;PW start
        rcall   setPW                       ;

;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

m00:    rcall   delay1ms                    ;poll cycle 1 ms
        rcall   service                     ;key and LED service
        rcall   getEnc                      ;get encoder
        breq    m00                         ;changes? no, wait

;- - - - - - - - - - - - - - - - - - - -

        ldi     ZL,(advTab<<1)              ;find encPos in PW advance table
m01:    lpm     a5,Z+                       ;get range
        cp      a5,encPos                   ;pos in range?
        lpm     a5,Z+                       ;get advance, next range
        brsh    m02                         ;yes, in range, exit find
        rjmp    m01                         ;loop

m02:    tst     a4                          ;encoder direction

.if ENCDIR == 0
        brmi    m03                         ;normal
.else
        brpl    m03                         ;reverse
.endif        

        add     encPos,a5                   ;encPos++               
        brcc    m04
        ldi     encPos,255
        rjmp    m04

m03:    sub     encPos,a5                   ;encPos--
        brcc    m04
        ldi     encPos,0

m04:    out     OCR0A,encPos                ;

        ldi     pwCnt,NUMPW-1               ;pwCnt max + 1 (next key) -> off
        tst     encPos                      ;pwCnt = encPos ? off : mid
        brne    PC+2                        ;
        ldi     pwCnt,0                     ;pwCnt mid-1 + 1 (next key) -> mid

        rjmp    m00

;-------------------------------------------------------------------------------

getEnc:
        in      a4,ENCPP

        lsl     encLast
        lsl     encLast
        andi    enclast,KEYCYCM

        mov     a5,a4
        andi    a5,(1<<ENCA)
        breq    PC+2
        ori     encLast,0x02

        andi    a4,(1<<ENCB)
        breq    PC+2
        ori     encLast,0x01

        ldi     ZL,(encTab<<1)
        add     ZL,encLast
        lpm     a4,Z        

        tst     a4
        ret

;-------------------------------------------------------------------------------

service:
        inc     sysTic                      ;every 1 ms    
        rcall   keyService

;- - - - - - - - - - - - - - - - - - - -

ledService:
        tst     encPos                      ;every 32 ms
        brne    st08

        mov     a4,sysTic
        andi    a4,0x1f
        breq    st08
        cbi     SLEDP,SLED
        ret

st08:   sbi     SLEDP,SLED                
st09:   ret

;---------------------------------------

keyService:
        mov     a4,sysTic                   ;every 16 ms
        andi    a4,0x0f
        brne    st09

        sbic    KEYPP,KEY                   ;key press?
        rjmp    keyRel                      ;no, release

keyPre: inc     keyCnt                      ;restrict counter
        brne    PC+2
        dec     keyCnt

        cpi     keyCnt,KLONGT               ;long press?
        brne    ky09                        ;no, exit

;- - - - - - - - - - - - - - - - - - - -

keyLong:
        ret

;- - - - - - - - - - - - - - - - - - - -

keyRel: cpi     keyCnt,KSHORT
        brlo    ky08

        cpi     keyCnt,KLONGT
        brsh    ky08

;- - - - - - - - - - - - - - - - - - - -

keyShort:    
        inc     pwCnt
        cpi     pwCnt,NUMPW
        brlo    PC+2
        clr     pwCnt
        rcall   setPW

;- - - - - - - - - - - - - - - - - - - -

ky08:   clr     keyCnt
ky09:   ret

;-------------------------------------------------------------------------------

setPW:
        ldi     ZL,(pwTab<<1)           
        add     ZL,pwCnt              
        lpm     encPos,Z    
        out     OCR0A,encPos              
        ret

;-------------------------------------------------------------------------------
;1 ms @ 9.6 MHz

delay1ms:
        ldi     a7,13
        ldi     a6,245
        dec     a6
        brne    PC-1
        dec     a7
        brne    PC-4

        ret

;-------------------------------------------------------------------------------
