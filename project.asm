.include "m2560def.inc"
.equ LCD_RS = 7
.equ LCD_E = 6
.equ LCD_RW = 5
.equ LCD_BE = 4
.equ LCD_BL = 3;back light
.equ F_CPU = 16000000
.equ DELAY_1MS = F_CPU / 4 / 1000 - 4
.def index = r3
.def power = r28
.def col = r16 ; stores the current column being scanned
.def row = r17 ; stores the current row
.def cmask = r18 ; column mask used to determine which column to give low signal
.def rmask = r19 ; row mask used to find out if any row has low signal
.def temp = r20
.def temp2 = r22
.def pattern = r21 ; stores the key pressed 
.def status = r23 ; bit 0 set when in entry mode, bit 1 set when in running mode
				  ; bit 2 set when in paused mode, bit 3 set when in finished mode
				  ; bit 4 set when door open (0 when closed), bit 5 set when in power level
				  ; bit 6 set when the turntable rotates clockwise, 0 anticlockwise
				  ; bit 7 set when the LCD light is on, cleared when off
.def debouncing = r29;1 when key is entered
.def old_status = r4
.def last_turntable_char = r25
.def sixteen = r6
.def counter = r7
.def back_lit_value = r13

.macro is_digit ; checks if the value in pattern is a digit between 0-9
	push temp
	ldi temp, 9
	cpi @0, 0
	brlo not_digit
	cp temp, @0
	brlo not_digit
	ser temp 
	bst temp, 0 ; sets the T bit in the SREG if it is a digit
	rjmp end
not_digit:
	clr temp ; clears the T bit in the SREG if it is a digit
	bst temp, 0
end:
	pop temp
.endmacro

.macro set_bit
	push temp
	ser temp
	bst temp, 0
	bld @0, @1
	pop temp
.endmacro

.macro clear_bit
	push temp
	clr temp
	bst temp, 0
	bld @0, @1
	pop temp
.endmacro	


.macro lcd_set
	sbi PORTA,@0
.endmacro


.macro lcd_clr
	cbi PORTA,@0
.endmacro


.macro do_lcd_command
	ldi r16,@0
	rcall lcd_command
	rcall lcd_wait
.endmacro

.macro do_lcd_data
	rcall lcd_data
	rcall lcd_wait
.endmacro

.org 0x0000
	jmp RESET
.org INT0addr
	jmp EXIT_INT0
.org INT1addr
	jmp EXIT_INT1
.org OVF2addr ; timer overflow for back lit
	jmp TIMER_OVF2
.org OVF0addr ; timer interrupt
	jmp TIMER_OVF0

RESET:
	ldi temp,high(RAMEND) ; sets up the stack pointer
	out SPH,temp
	ldi temp,low(RAMEND)
	out SPL,temp
	ldi temp,0xF0 ; set the columns up for output, rows for input
	sts DDRL,temp
	ldi temp,0xEF
	sts PORTL,temp

	clr status
	set_bit status, 0 ; start off in entry mode with door closed
	
	//set up pwm for motor. use timer3 for output compare match
	ser temp
	out DDRE,temp
	clr temp
	out PORTE,temp
	sts OCR3BL,temp
	sts OCR3BH,temp
	//set up phase correct PWM mode
	ldi temp, (1 << CS30)
	sts TCCR3B, temp
	ldi temp, (1<< WGM30)|(1<<COM3B1)
	sts TCCR3A, temp

	//set up phase correct PWM mode for back light(output compare)
	ldi temp,0
	sts OCR3AL,temp
	clr temp
	sts OCR3AH,temp
	lds temp,TCCR3B
	ori temp, (1 << CS30)
	sts TCCR3B, temp
	lds temp,TCCR3A
	ori temp, (1<< WGM30)|(1<<COM3A1)
	sts TCCR3A, temp
	
	//setup ports for keypad and LED
	ser temp
	out DDRF,temp;For keypad
	out DDRA,temp;For control of the display
	out DDRC,temp;for LED
	ldi temp,0b00001000
	out DDRD,temp
	clr temp
	out PORTD,temp
	out PORTF,temp
	out PORTA,temp
	out PORTC,temp
	do_lcd_command 0b00111000;setting format 2*5*7 lec notes 36
	do_lcd_command 0b00001101 ; Cursor on, bar, no blink, lecture notes 35
	do_lcd_command 0b00000110;set entry mode
	do_lcd_command 0b00000010;cursorhome
	do_lcd_command 0b00000001;clear display

	// setting up the timer interrupt every 128us
	ldi temp, 0b00000000
	out TCCR0A, temp 
	sts TCCR2A, temp
	ldi temp, 0b00000010
	out TCCR0B, temp
	sts TCCR2B, temp
	ldi temp, 1<<TOIE0
	sts TIMSK0, temp 

	//information reset
	clr temp
	sts Buffer,temp
	sts Buffer+1,temp
	sts Buffer+2, temp
	sts Buffer+3, temp
	sts Time,temp
	sts Time+1,temp
	sts Halfseconds, temp
	sts Seconds_not_running, temp
	sts Timecounter_not_running, temp
	sts Timecounter_not_running+1, temp
	sts Tempcounter,temp
	sts Tempcounter+1,temp
	sts Seconds_finished, temp
	
	mov back_lit_value,temp 


	//external interrupt setup
	ldi temp,(2 << ISC00 | 2 << ISC10);setting mode falling edge
	sts EICRA,temp
	in temp,EIMSK
	ori temp,(1 << INT0 | 1 << INT1)
	out EIMSK,temp   ;enable external interrupt 0 and 1
	
	ldi r24, 1 ; start off displaying closed door 
	rcall Display_OC
	
	ldi temp,16
	mov sixteen,temp
	clr counter
	ldi temp,0
	mov index,temp
	ldi debouncing,0
	clr temp
	sei

main:
	clr col
	ldi cmask,0xEF ; start off with column 0 having low signal

colloop:
	cpi col,4 ; if got to col 4, start scanning again from col 0
	breq update_character
	ori cmask,0x0F
	sts PORTL,cmask ; give the current column low signal 
	ldi temp,255
delay:
	cpi temp,0
	breq go_on
	dec temp
	rjmp delay
go_on:
	lds temp,PINL ; reads in the signals from PORT L
	andi temp,0x0F ; isolate the input from the rows
	cpi temp,0xF ; if all rows are low, proceed to next col
	breq nextcol
	clr row ; some row is low, need to determine which
	ldi rmask,1 ; starting from row 07

rowloop:
	cpi row,4
	breq nextcol
	mov temp2,temp
	and temp2,rmask ; if the and results in 0 then the current row is low
	breq convert
	lsl rmask ; otherwise check the next row
	inc row
	rjmp rowloop

nextcol:
	inc col ; move on to next col
	lsl cmask
	rjmp colloop

update_character:
	cpi debouncing,1;key was pressed before
	brne main
	clr debouncing
	rjmp continue

convert: ; arrives here when a low signal has been found 	
	ldi debouncing,1
	cpi col, 3 ; if its in col 3 then a letter is pressed
	breq letters

	cpi row, 3 ; if its in row 3 then a symbol
	breq symbols_or_0 ; or 0 is pressed
	
	ldi temp, 3 ; else a number was pressed
	mul row, temp ; this does 3 * row + col + 1
	mov temp, R0 ; which finds out which number
	inc temp ; is pressed
	add temp,col
	mov pattern,temp
	
	rjmp main

letters: ; find which letter pressed
	ldi temp, 'A'
	add temp, row
	mov pattern,temp
	rjmp main

symbols_or_0: ; find which symbol pressed, or if 0
	cpi col, 0 ; col 0 is a star
	breq star
	cpi col, 1 ; col 1 is 0
	breq zero
	ldi temp, '#' ; otherwise it is #
	mov pattern,temp
	rjmp main
	
star:
	ldi temp, '*'
	mov pattern,temp
	rjmp main
	
zero:
	ldi temp, 0		 
	mov pattern,temp
	rjmp main

continue:
	rcall turn_on_backlight
	rjmp act_on_input

act_on_input: ; deals with the key entered on the keypad
	sbrc status,4;if door is opened,ignore
	rjmp main	   
    sbrc status,5
    rjmp in_power_state ; go to select power level
	sbrc status, 0 ; deal differently with input depending what mode the microwave is in
	rjmp in_entry_mode
	sbrc status, 1
	rjmp in_running_mode
	sbrc status, 2
	rjmp in_paused_mode
	rjmp in_finished_mode

in_entry_mode:
	cpi pattern, '*'
	breq start_running
	cpi pattern, '#'
	breq clear_entered_jump
	cpi pattern, 'A'
	breq power_selection_state_jump
	is_digit pattern
	brts entering_time_jump ; the T bit is set if pattern holds a digit
	jmp main ; if it is none of the above then no operation needs to be done

in_running_mode:
	cpi pattern, '*'
	breq add_one_minute_jump
	cpi pattern, '#'
	breq pause
	cpi pattern, 'C'
	breq add_thirty_seconds_jump
	cpi pattern, 'D'
	breq subtract_thirty_seconds_jump
	jmp main ; if it is none of the above then no operation needs to be done

in_paused_mode:
	cpi pattern, '*'
	breq resume_cooking_jump
	cpi pattern, '#'
	breq cancel_operation_jump
	jmp main ; if it is none of the above then no operation needs to be done

in_finished_mode:
	cpi pattern, '#'
	breq return_to_entry_mode
	jmp main ; if it is none of the above then no operation needs to be done

add_thirty_seconds_jump:
	rjmp add_thirty_seconds

add_one_minute_jump:
	rjmp add_one_minute

subtract_thirty_seconds_jump:
	rjmp subtract_thirty_seconds

resume_cooking_jump:
	rjmp resume_cooking

clear_entered_jump:
	rjmp clear_entered

entering_time_jump:
	rjmp entering_time

power_selection_state_jump:
	rjmp power_selection_state

cancel_operation_jump:
	rjmp cancel_operation

pause:
	ldi r24,0;stopping the motor
	rcall Motor_Spin
	clear_bit status, 1 ; leave running mode
	set_bit status, 2 ; enter paused mode
	rjmp main

start_running:
	push temp
	push r17
	push r24
	clear_bit status, 0 ; leave entry mode
	set_bit status, 1 ; now in running mode
	rcall Display_LED
	ldi temp, 0b01000000 ; if the turntable rotated clockwise last then
	eor status, temp ; it rotates anticlockwise now, otherwise it rotates clockwise
	ldi r24, 2 ; start the turntable display
	rcall Display_Turntable
	ldi r17,0
	cp index,r17
	breq give_buffer_1min
calling_transfer:
	rcall Transfer_To_Time
	pop r24
	pop r17
	pop temp
	rjmp main

give_buffer_1min:
	inc index;afte this index = 1
	sts Buffer,index
	inc index
	inc index;index = 3
	rjmp calling_transfer
return_to_entry_mode:
	clear_bit status, 3 ; leave finished mode
	set_bit status, 0 ; enter entry mode
	do_lcd_command 0b00000001;clear display
	ldi r24,1;display closed state
	rcall Display_OC
	rjmp main

resume_cooking:
	clear_bit status, 2 ; leave paused mode
	set_bit status, 1 ; enter running mode
	rjmp main

add_one_minute:
	push r20
	lds r20, Time
	inc r20
	sts Time, r20
	pop r20
	rjmp main

add_thirty_seconds: ; adds 30 seconds to the cooking time
	push r20
	push r21
	push r22
	lds r20, Time+1 ; r20 now stores the amount of seconds
	ldi r21, 30
	add r20, r21
	lds r21, Time ; r21 now holds the amount of minutes
	cpi r20, 100
	ldi r22, 99
	cpc r21, r22
	brge max_time
	cpi r20, 100 ; maximum number of seconds is 99
	brge adjust_minute_addition ; need to increment the minutes if seconds is 100 or over
	sts Time+1, r20 
	rjmp finished_adding_seconds

adjust_minute_addition:
	inc r21
	sts Time, r21
	subi r20, 60 ; since a minute is added, there is now 60 less seconds
	sts Time+1, r20
	rjmp finished_adding_seconds

max_time:
	ldi r21, 99
	sts Time, r21
	sts Time+1, r21

finished_adding_seconds:
	pop r22
	pop r21
	pop r20 
	jmp main

subtract_thirty_seconds: ; subtracts 30 seconds from the cooking time
	push r20
	push r21
	push r22
	lds r20, Time+1
	lds r21, Time
	cpi r20, 31
	clr r22			  ; if subtracting 30 seconds causes the cooking time to be 0 minutes and 
	cpc r21, r22	  ; 0 seconds or less then the cooking is finished
	brlt no_time_left  
	cpi r20, 30 ; if subtracting 30 seconds leaves greater than or exactly 0 seconds
	brge load_new_seconds ; then that is simply the new amount of seconds
	dec r21 ; otherwise need to decrement the minutes and adjust the seconds
	ldi r22, 30 ; in this case the new seconds is 60- (30 - old amount of seconds)
	add r22, r20
	sts Time, r21
	sts Time+1, r22
	rjmp finished_subtracting_seconds
		
load_new_seconds:
	subi r20, 30
	sts Time+1, r20
	rjmp finished_subtracting_seconds

no_time_left:
	clear_bit status, 1 ; leaving running mode
	set_bit status, 3 ; entering finished mode
	ldi r24, 0 ; turn the motor off
	sts Time, r24
	sts Time+1,r24
	rcall Motor_Spin
	rcall Clear_LED
	rcall Display_Finished_Mode

finished_subtracting_seconds:
	pop r22
	pop r21
	pop r20
	jmp main

power_selection_state:	   
    push r16
	rcall Display_Power_Text
	set_bit status,5
    pop r16
    jmp main

in_power_state:
    push r16
	push r24
    cpi pattern, '#'
    breq exitPowerState
    cpi pattern, 4    
    brlo p1 ; less than 4
	pop r24
    pop r16
    ret ; invalid input, polling to read next input
p1:
    cpi pattern, 1 
    brsh p2 ; greater than or equal to 1
	pop r24
    pop r16
    ret ; invalid input, polling to read next input
p2:
    mov power,pattern
	rcall clear_LED
	rcall Display_LED

exitPowerState:
    clear_bit status,5
	do_lcd_command 0b00000001;clear display
	ldi r24,0
	cp index,r24
	breq continue_exiting
	rcall Display_Buffer
continue_exiting:
	ldi r24,1
	rcall display_OC
	pop r24
    pop r16
    jmp main

cancel_operation:
	push r20
	push r24
	push r16
	clr r20
	sts Buffer, r20
	sts Buffer+1, r20
	sts Buffer+2,r20
	sts Buffer+3,r20
	sts Time, r20
	sts Time+1, r20
	clear_bit status, 2
	set_bit status, 0
	do_lcd_command 0b00000010;cursorhome
	do_lcd_command 0b00000001;clear display
	ldi r24,1
	rcall Display_OC
	rcall Clear_LED
	pop r16
	pop r24
	pop r20
	rjmp main
	
clear_entered:
	push r20
	push r24
	push r16
	clr r20
	sts Buffer, r20
	sts Buffer+1, r20
	sts Buffer+2,r20
	sts Buffer+3,r20
	mov index,r20
	sts Time, r20
	sts Time+1, r20
	do_lcd_command 0b00000010;cursorhome
	do_lcd_command 0b00000001;clear display
	ldi r24,1
	rcall Display_OC
	rcall Clear_LED
	pop r16
	pop r24
	pop r20
	rjmp main

entering_time:	
	push r16
    push r17
	push temp
	push ZL
	push ZH
	ldi r17,4
	cp index,r17
	breq return3 ;4digtis have been entered  
	clr temp
	ldi ZL,low(Buffer)
	ldi ZH,high(Buffer)
	add ZL,index
	adc ZH,temp
	st Z,pattern
	inc index
return3:
	rcall Display_Buffer
	pop ZH
	pop ZL
	pop temp
    pop r17
    pop r16
	jmp main

lcd_command:
	out PORTF,r16
	rcall sleep_1ms
	lcd_set LCD_E ;
	rcall sleep_1ms
	lcd_clr LCD_E
	rcall sleep_1ms
	ret
	
lcd_data:
	out PORTF,r16
	lcd_set LCD_RS
	rcall sleep_1ms
	lcd_set LCD_E
	rcall sleep_1ms
	lcd_clr LCD_E
	rcall sleep_1ms
	lcd_clr LCD_RS
	ret

lcd_wait:
	push r16
	clr r16 ; changing portF to input port
	out PORTF,r16
	lcd_set LCD_RW
lcd_wait_loop:
	rcall sleep_1ms
	lcd_set LCD_E
	rcall sleep_1ms
	in r16,PINA
	lcd_clr LCD_E; can we get rid of this line?
	sbrc r16,7
	rjmp lcd_wait_loop
	lcd_clr LCD_RW
	ser r16
	out DDRF,r16
	pop r16
	ret
	
sleep_1ms:
	push XL
	push XH
	ldi XL,low(DELAY_1MS)
	ldi XH,high(DELAY_1MS)
loop:
	sbiw XH:XL,1
	brne loop
	pop XH
	pop XL
	ret

sleep_5ms:
	rcall sleep_1ms
	rcall sleep_1ms
	rcall sleep_1ms
	rcall sleep_1ms
	rcall sleep_1ms
	ret

Display_Finished_Mode:
	push r16
	push r24
	do_lcd_command 0b00000001;clear display
	do_lcd_command 0b00000010 ; cursor home
	ldi r16, 'D'
	do_lcd_data
	ldi r16, 'O'
	do_lcd_data
	ldi r16, 'N'
	do_lcd_data
	ldi r16, 'E'
	do_lcd_data
	do_lcd_command 0b11000000 ; cursor second line

	ldi r16, 'R'
	do_lcd_data
	ldi r16, 'e'
	do_lcd_data
	ldi r16, 'm'
	do_lcd_data
	ldi r16, 'o'
	do_lcd_data
	ldi r16, 'v'
	do_lcd_data
	ldi r16, 'e'
	do_lcd_data
	ldi r16, ' '
	do_lcd_data
	ldi r16, 'f'
	do_lcd_data
	ldi r16, 'o'
	do_lcd_data
	ldi r16, 'o'
	do_lcd_data
	ldi r16, 'd'
	do_lcd_data
	ldi r24,1
	rcall display_OC
	pop r24
	pop r16
	ret

//call this function after setting the r24 to the corresponding 
//value of the turntable you want
Display_Turntable:
	push r16
	push r21
	do_lcd_command 0b00000010 ; cursor home
	rcall move_cursor
	mov last_turntable_char, r24
	cpi r24,0;0=-
	breq display_0
	cpi r24,1;1=\
	breq display_1
	cpi r24,2;2=|
	breq display_2
	cpi r24,3;3=/
	breq display_3
	
display_0:
	ldi r16,45
	do_lcd_data
	rjmp return_0

display_1:
	ldi r16,164
	do_lcd_data
	rjmp return_0

display_2:
	ldi r16,124
	do_lcd_data
	rjmp return_0

display_3:
	ldi r16,47
	do_lcd_data
	rjmp return_0

return_0:
	pop r21
	pop r16	
	ret

Display_Time:
	push r16
	push r21
	push XL
	push XH
	do_lcd_command 0b00000010;cursor home
	lds XL,Time
	clr XH
	rcall IntToA
	ldi r16,':'
	do_lcd_data 
	lds XL,Time+1
	clr XH
	rcall IntToA
	pop XH
	pop XL
	pop r21
	pop r16
	ret

//set r24 to the 0 for "O" ,1 for "C"
Display_OC:
	push r21
	push r16

	do_lcd_command 0b11000000;move to second line
    rcall move_cursor
	cpi r24,0
	breq set_to_O
	ldi r16,'C'
	do_lcd_data
	pop r16
	pop r21
	ret
set_to_O:
	ldi r16,'O'
	do_lcd_data 
	pop r16
	pop r21
	ret

//a function of moving the cursor to the right most position
//on the display with the cursor stays at the beginning of any
//line 
move_cursor:
	push r16
	push r21
	ldi r21,15
moving:
	cpi r21,0
	breq return_1
	do_lcd_command 0b00010100;move cursor to right by 1
	dec r21
	rjmp moving
return_1:
	pop r21
	pop r16
	ret	
	
Display_Power_Text:
	push r16
	do_lcd_command 0b00000010 ;cursor home
	ldi r16,'S'
	do_lcd_data 
	ldi r16,'e'
	do_lcd_data 
	ldi r16,'t'
	do_lcd_data 
	ldi r16,' '
	do_lcd_data 
	ldi r16,'P'
	do_lcd_data 
	ldi r16,'o'
	do_lcd_data 
	ldi r16,'w'
	do_lcd_data 
	ldi r16,'e'
	do_lcd_data 
	ldi r16,'r'
	do_lcd_data 
	ldi r16,'1'
	do_lcd_data 
	ldi r16,'/'
	do_lcd_data 
	ldi r16,'2'
	do_lcd_data 
	ldi r16,'/'
	do_lcd_data 
	ldi r16,'3'
	do_lcd_data 
	pop r16
	ret

//use XH:XL as argument(i.e. parameters passed into this function)
IntToA:
	push r16
	push r19
	push r20
	push r21;hundred
	push r22;tens
	push r23;one
	ldi r19,'0'
	clr r21
	clr r22
	clr r23
ten:
	cpi XL,10
	brsh addTens
	mov r16,r22
	add r16,r19;+'0'
	do_lcd_data	
one:
	cpi XL,1
	brsh addOnes
	mov r16,r23
	add r16,r19;
	do_lcd_data	
	pop r23
	pop r22
	pop r21
	pop r20
	pop r19
	pop r16
	ret	
	
addTens:
	inc r22
	subi XL,10
	rjmp ten
addOnes:
	inc r23
	subi XL,1
	rjmp one


//use r24 as parameter passed in this function
//255:full speed;128:half speed;64:25% speed
Motor_Spin:
	push temp
	sts OCR3BL,r24
	clr temp
	sts OCR3BH,temp
	pop temp
	ret

Display_Buffer:
	push r16 ;do_lcd_data register
	push r17 ;'0' offset
	push r18 ;store the value of index in order to print zero before digits
	push r19 
	push r20 ;print counter
	push ZH ;pointer to digits in buffer
	push ZL
	ldi r19,4
	mov r18,index
	ldi r17,'0'
	clr r20
	ldi ZH,high(Buffer)
	ldi ZL,low(Buffer)
	do_lcd_command 0b00000010 ;cursor home
print_zero:	
	cpi r18,4;digit entered and 4
	breq print_digits
	mov r16,r17
	do_lcd_data
	inc r18
	inc r20
	cpi r20,2
	brne no_printing_colon
	ldi r16,':'
	do_lcd_data
no_printing_colon:
	rjmp print_zero

print_digits:
	ld r16,Z
	add r16,r17
	do_lcd_data
	inc r20
	adiw ZH:ZL,1
	cpi r20,2
	brne no_printing_colon_again
	ldi r16,':'
	do_lcd_data
no_printing_colon_again:
	cpi r20,4
	breq return5
	rjmp print_digits		
return5:
	pop ZL
	pop ZH
	pop r20
	pop r19
	pop r18
	pop r17
	pop r16
	ret


//Transfer values from Buffer to Time in data space
Transfer_To_Time:
	push r16
	push r17;index buffer
    push r18;lower digit buffer
    push r19;higher digit buffer
	clr r17
	ldi r16,10
	
	mov r17,index
	cpi r17,1
	breq one_digit
	cpi r17,2
	breq two_digit
	cpi r17,3
	breq three_digit
	lds r19,Buffer
	lds r18,Buffer+1
	mul r19,r16
	mov r19,r0
	add r19,r18
	sts Time,r19

	lds r19,Buffer+2
	lds r18,Buffer+3
	mul r19,r16
	mov r19,r0
	add r19,r18
	sts Time+1,r19
	rjmp return4
one_digit:
	lds r19,Buffer
	sts Time+1,r19
	rjmp return4

two_digit:
    lds r19,Buffer
    lds r18,Buffer+1
    mul r19,r16
    mov r19,r0;
	add r19,r18
    sts Time+1,r19
	rjmp return4

three_digit:
	lds r19,Buffer+1
    lds r18,Buffer+2
    mul r19,r16
    mov r19,r0;
	add r19,r18
    sts Time+1,r19
	
	lds r19,Buffer
	sts Time,r19
	rjmp return4
return4:
	clr index
    pop r19
    pop r18
    pop r17
    pop r16
    ret

not_running_timer:
	push r24
	in r24, SREG
	push r24
	push r26
	push r27
	cpi debouncing, 0
	brne clear_seconds
	lds r26, Timecounter_not_running 
	lds r27, Timecounter_not_running+1
	adiw r27:r26, 1
	cpi r26, low(7812) ; this is 1s
	ldi r24, high(7812)
	cpc r27, r24
	brne not_second
	clr r26
	sts Timecounter_not_running, r26
	sts Timecounter_not_running+1, r26
	lds r27, Seconds_finished
	inc r27 
	sbrc status, 3
	rjmp finished_six
continue_with_second:
	lds r26, Seconds_not_running
	inc r26
	cpi r26, 10
	brne not_ten
	rcall back_light_fading
clear_seconds:
	clr r26
	sts Seconds_not_running, r26
	rjmp finish_not_running_timer
not_ten:
	sts Seconds_not_running, r26
	rjmp finish_not_running_timer
finished_six:
	cpi r27, 6
	brge continue_with_second
	; the code to enter for speaker
	sts Seconds_finished, r27
	rjmp continue_with_second
not_second:
	sts Timecounter_not_running, r26
	sts Timecounter_not_running+1, r27
finish_not_running_timer:	
	pop r27
	pop r26
	pop r24
	out SREG, r24
	pop r24
	reti
	

TIMER_OVF0:
	sbrs status, 1 ; if not in running mode then just return
	rjmp not_running_timer
	push r24
	in r24, SREG
	push r24
	push r26
	push r27
	push temp
	lds r26, Timecounter 
	lds r27, Timecounter+1
	adiw r27:r26, 1
	cpi r26, low(1953) ; this is a 250ms
	ldi temp, high(1953)
	cpc r27, temp
	breq quarter_second
	cpi r26, low(3906) ; this is 500ms
	ldi temp, high(3906)
	cpc r27, temp
	breq half_second
	cpi r26, low(7812) ; this is 1s
	ldi temp, high(7812)
	cpc r27, temp
	breq one_second
	rjmp finish_timer_interrupt ; if it not 250ms, 500ms or 1s don't do anything

quarter_second:
	cpi power, 3 ; if in power mode 3, then the motor should only run for 250ms
	brne finish_timer_interrupt
	ldi r24, 0 ; so shut it off now
	rcall Motor_Spin
	rjmp finish_timer_interrupt

half_second:
	cpi power, 2 ; if in power mode 2, then the motor should only spin for 500ms
	brne update_half_seconds
	ldi r24, 0 
	rcall Motor_Spin
update_half_seconds:
	lds temp, Halfseconds ; update the amount of half seconds
	inc temp
	cpi temp, 5 ; if there has been 5 half seconds
	breq five_halfseconds ; then the turntable rotates
	sts Halfseconds, temp
	rjmp finish_timer_interrupt

five_halfseconds:
	clr temp ; start a new round of half seconds
	sts Halfseconds, temp
	rcall rotate_turntable
	rjmp finish_timer_interrupt

one_second:
	rcall one_second_less ; the timer has one second less
	clr r26
	clr r27
	lds temp, Halfseconds
	inc temp
	cpi temp, 5
	breq five_halfseconds
	sts Halfseconds, temp

finish_timer_interrupt:
	sts Timecounter, r26
	sts Timecounter+1, r27
	pop temp
	pop r27
	pop r26
	pop r24
	out SREG, r24
	pop r24
	reti

one_second_less:
	push r24
	push r26
	push r27
	push temp
	lds r26, Time+1 ; this is the seconds in the timer
	lds r27, Time ; this is the minutes
	cpi r26, 0 ; if the timer has 0 seconds and 0 minutes then the cooking is over
	ldi temp, 0
	cpc r27, temp
	breq cooking_finished
	cpi r26, 0 ; if there are 0 seconds then the timer has now 59 seconds and one minute less
	breq one_minute_less
	dec r26 ; otherwise just decrease the seconds
	rcall Display_Time
	ldi r24, 255 ; all power modes the motor starts off spinning
	rcall Motor_Spin
	rjmp finish_one_second_less

one_minute_less:
	dec r27
	ldi r26, 59
	rcall Display_Time
	ldi r24, 255 ; all power modes the motor starts off spinning
	rcall Motor_Spin
	rjmp finish_one_second_less

cooking_finished:
	clear_bit status, 1 ; running mode is over
	set_bit status, 3 ; now in finished mode
	ldi r24, 0 ; so turn the motor off
	rcall Clear_LED
	rcall Motor_Spin
	rcall Display_Finished_Mode
	sts Seconds_finished, r24 ; it has been finished for 0 seconds 

finish_one_second_less:
	sts Time+1, r26
	sts Time, r27
	pop temp
	pop r27
	pop r26
	pop r24
	ret	         

rotate_turntable:
	push r24
	sbrs status, 6 ; set if the turntable rotates clockwise
	rjmp anti_clockwise
	cpi last_turntable_char, 0
	breq now_1
	cpi last_turntable_char, 1
	breq now_2
	cpi last_turntable_char, 2
	breq now_3
	cpi last_turntable_char, 3
	breq now_0

anti_clockwise:
	cpi last_turntable_char, 0
	breq now_3
	cpi last_turntable_char, 1
	breq now_0
	cpi last_turntable_char, 2
	breq now_1
	cpi last_turntable_char, 3
	breq now_2

now_0:
	ldi r24, 0
	rjmp finish_rotating

now_1:
	ldi r24, 1
	rjmp finish_rotating

now_2:
	ldi r24, 2
	rjmp finish_rotating

now_3:
	ldi r24, 3

finish_rotating:
	rcall Display_Turntable
	pop r24
	ret

EXIT_INT1:
	sbrc status, 4
	reti
	push r18
	push r24
	in r24, sreg
	push r24
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	in r18,EIFR;clearing bouncing
	cbr r18,0
	out EIFR,r18
	ldi r24, 0
	rcall Display_OC

	in r24,PORTD
	ori r24,0b00001000
	out PORTD,r24
	mov old_status, status
	set_bit status, 4 ; the door is open
	sbrc status, 1 ; if in running mode then pause
	rjmp enter_pause
	sbrc status, 3
	rjmp enter_entry
	rjmp return_from_push

enter_pause:
	clear_bit status, 1 
	set_bit status, 2 ; entering pause mode
	ldi r24,0
	rcall Motor_Spin
	rjmp return_from_push

enter_entry:
	clear_bit status, 3
	set_bit status, 0 ; entering entry mode	
	do_lcd_command 0b00000001;clear display
	ldi r24, 0
	rcall Display_OC
	rjmp return_from_push	

EXIT_INT0:
	sbrs status, 4
	reti
	push r18
	push r24
	in r24, sreg
	push r24
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	rcall sleep_5ms
	in r18,EIFR;clearing bouncing
	cbr r18,1
	out EIFR,r18
	mov status, old_status
	clear_bit status, 4 ; the door is closed

	ldi r24, 1
	rcall Display_OC
	in r24,PORTD
	andi r24,0b11110111
	out PORTD,r24

return_from_push:
	pop r24
	out sreg, r24
	pop r24
	pop r18
	reti

Display_LED:
	push r18
	push r17
	cpi power,3
	breq LED_1
	cpi power,2
	breq LED_2
	ser r17
	out PORTC,r17

return_LED:
	pop r17
	pop r18
	ret

LED_1:
	sbi PORTC,0
	sbi PORTC,1
	rjmp return_LED

LED_2:
	sbi PORTC,0
	sbi PORTC,1
	sbi PORTC,2
	sbi PORTC,3
	rjmp return_LED

Clear_LED:
	push  r17
	clr r17
	out PORTC,r17
	pop r17
	ret

TIMER_OVF2:
	push r16
	in r16,sreg
	push r16
	push r26
	push r27
	push r24
	inc counter
	lds r27,Tempcounter+1
	lds r26,Tempcounter
	adiw r27:r26,1
	cpi r26,low(3906)
	ldi r24,high(3906)
	cpc r27,r24
	breq stopping_ovf1
	sts Tempcounter+1,r27
	sts Tempcounter,r26
	cp counter,sixteen
	brne return_from_ovf2
	clr counter
	dec back_lit_value
	sts OCR3AL,back_lit_value
return_from_ovf2:
	pop r24
	pop r27
	pop r26
	pop r16
	out sreg,r16
	pop r16
	reti

stopping_ovf1:
	clr temp
	sts TIMSK2, temp 
	rjmp return_from_ovf2

back_light_fading:
	push r18
	push r19
	clr r18
	sts Tempcounter,r18
	sts Tempcounter+1,r18
	sbrs status, 7
	rjmp finish_back_light_fading
	ser r19
	mov back_lit_value,r19
	sts OCR3AL,r19
	ldi r18,1 << TOIE2
	sts TIMSK2, r18
	clear_bit status, 7 ; the backlight is now off 
finish_back_light_fading:
	pop r19
	pop r18
	ret

turn_on_backlight:
	push temp
	push r18
	ldi r18,255
	sts OCR3AL,r18
	mov back_lit_value,r18
	clr temp
	sts TIMSK2, temp
	set_bit status, 7 ; the backlight is now on 
	pop r18
	pop temp
	ret
.dseg
Buffer:
	.byte 4 ; holding the four values entered
Time:
	.byte 2 ; format:"xx:xx",minutes:seconds
Timecounter:
	.byte 2 ; storing the amount of timer0 interrupts
Halfseconds:
	.byte 1
Seconds_not_running:
	.byte 1
Tempcounter:
	.byte 2 ; storing the amount of timer1 interrupts
Timecounter_not_running:
	.byte 2
Seconds_finished:
	.byte 1

