.include "m2560def.inc"
.equ LCD_RS = 7
.equ LCD_E = 6
.equ LCD_RW = 5
.equ LCD_BE = 4
.equ LCD_BL = 3;back light
.equ F_CPU = 16000000
.equ DELAY_1MS = F_CPU / 4 / 1000 - 4
.def index = r3
.def power = r4
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
.def r3 = debouncing;0 when key is pressed 0xFF when key is released(0 by default)
.macro is_digit ; checks if the value in pattern is a digit between 0-9
	push temp
	ldi temp, 9
	cpi @0, 0
	brlo not_digit
	cpi temp, @0
	brlo not_digit
	sbr temp, 0 
	bst temp, 0 ; sets the T bit in the SREG if it is a digit
	rjmp end
not_digit:
	cbr temp, 0 ; clears the T bit in the SREG if it is a digit
	bst temp, 0
end:
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

RESET:
	ldi temp,high(RAMEND) ; sets up the stack pointer
	out SPH,temp
	ldi temp,low(RAMEND)
	out SPL,temp
	ldi temp,0xF0 ; set the columns up for output, rows for input
	sts DDRL,temp
	clr status
	sbr status, 0 ; start off in entry mode with door closed
	
	//set up pwm for motor. use timer3 for output compare match
	ser temp
	out DDRE
	clr temp
	out PORTE
	sts OCR3L,temp
	sts OCR3H,temp
	//set up phase correct PWM mode
	ldi temp, (1 << CS30)
	sts TCCR3B, temp
	ldi temp, (1<< WGM30)|(1<<COM3B1)
	sts TCCR3A, temp

	//set up phase correct PWM mode for back light
	clr temp
	sts OCR5L,temp
	sts OCR5H,temp
	ldi temp, (1 << CS50)
	sts TCCR5B, temp
	ldi temp, (1<< WGM50)|(1<<COM5B1)
	sts TCCR5A, temp
	
	//setup ports for keypad and LED
	ser temp
	out DDRF,temp;For keypad
	out DDRA,temp;For control of the keypad
	out DDRC,temp;for LED
	clr temp
	out PORTF,temp
	out PORTA,temp
	out PORTC,temp
	do_lcd_command 0b00111000;setting format 2*5*7 lec notes 36
	do_lcd_command 0b00001101 ; Cursor on, bar, no blink, lecture notes 35
	do_lcd_command 0b00000110;set entry mode
	do_lcd_command 0b00000010;cursorhome
	do_lcd_command 0b00000001;clear display


	//information reset
	clr temp
	sts Buffer,temp
	sts Buffer+1,temp
	sts Time,temp
	sts Time+1,temp
	sts Time+2,temp
	sts Time+3,temp
	
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
	sts PORTL,cmask ; give the current column low signal 

	lds temp,PINL ; reads in the signals from PORT L
	andi temp,0x0F ; isolate the input from the rows
	cpi temp,0xF ; if all rows are low, proceed to next col
	breq nextcol
	clr row ; some row is low, need to determine which
	ldi rmask,1 ; starting from row 0

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
	mov pattern,temp
	rjmp continue

convert: ; arrives here when a low signal has been found 
	
	cpi col, 3 ; if its in col 3 then a letter is pressed
	breq letters

	cpi row, 3 ; if its in row 3 then a symbol
	breq symbols_or_0 ; or 0 is pressed
	
	ldi temp, 3 ; else a number was pressed
	mul row, temp ; this does 3 * row + col + 1
	mov temp, R0 ; which finds out which number
	inc temp ; is pressed
	add temp,col
	
	ldi debouncing,1;not ready i.e. key is being pressed
	rjmp main

letters: ; find which letter pressed
	ldi temp, 'A'
	add temp, row
	ldi debouncing,1;not ready i.e. key is being pressed
	rjmp main

symbols_or_0: ; find which symbol pressed, or if 0
	cpi col, 0 ; col 0 is a star
	breq star
	cpi col, 1 ; col 1 is 0
	breq zero
	ldi temp, '#' ; otherwise it is #
	ldi debouncing,1;not ready i.e. key is being pressed
	rjmp main
	
star:
	ldi temp, '*'
	ldi debouncing,1;not ready i.e. key is being pressed
	rjmp main
	
zero:
	ldi temp, 0		 
	ldi debouncing,1;not ready i.e. key is being pressed
	rjmp main

continue:
	mov pattern,temp
	rjmp act_on_input

act_on_input: ; deals with the key entered on the keypad	   
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
	breq clear_entered
	cpi pattern, 'A'
	breq power_selection_state
	is_digit pattern
	brts entering_time ; the T bit is set if pattern holds a digit
	jmp main ; if it is none of the above then no operation needs to be done

in_running_mode:
	cpi pattern, '*'
	breq add_one_minute
	cpi pattern, '#'
	breq pause
	cpi pattern, 'C'
	breq add_thirty_seconds
	cpi pattern, 'D'
	breq subtract_thirty_seconds
	jmp main ; if it is none of the above then no operation needs to be done

in_paused_mode:
	cpi pattern, '*'
	breq resume_cooking
	cpi pattern, '#'
	breq cancel_operation
	jmp main ; if it is none of the above then no operation needs to be done

in_finished_mode:
	cpi pattern, '#'
	breq return_to_entry_mode
	jmp main ; if it is none of the above then no operation needs to be done

add_thirty_seconds: ; adds 30 seconds to the cooking time
	push r20
	push r21
	lds r20, Time+1 ; r20 now stores the amount of seconds
	ldi r21, 30
	add r20, r21
	cpi r20, 100 ; maximum number of seconds is 99
	brge adjust_minute_addition ; need to increment the minutes if it 100 or over
	sts Time+1, r20 
	rjmp finished_adding_seconds

adjust_minute_addition:
	lds r21, Time
	inc r21
	sts Time, r21
	subi r20, 60 ; since a minute is added, there is now 60 less seconds
	sts Time+1, r20

finished_adding_seconds:
	pop r21
	pop r20 
	jmp main		

subtract_thirty_seconds: ; subtracts 30 seconds from the cooking time
	push r20
	push r21
	push r22
	lds r20, Time+1
	lds r21, Time
	subi r20, 30
	cpi r20, 1
	clr r22			  ; if subtracting 30 seconds causes the cooking time to be 0 minutes and 
	cpc r21, r22	  ; 0 seconds or less then the cooking is finished
	brlt no_time_left  
	cpi r20, 0 ; if subtracting 30 seconds leaves greater than or exactly 0 seconds
	brge load_new_seconds ; then that is simply the new amount of seconds
	dec r21 ; otherwise need to decrement the minutes and adjust the seconds
	ldi r22, 30 ; in this case the new seconds is 60- (30 - old amount of seconds)
	add r22, r20
	sts Time+1, r22
	rjmp finished_subtracting_seconds
		
load_new_seconds:
	sts Time+1, r20
	rjmp finished_subtracting_seconds

no_time_left:
	cbr status, 1 ; leaving running mode
	sbr status, 3 ; entering finished mode
	rcall Display_Finished_Mode

finished_subtracting_seconds:
	pop r22
	pop r21
	pop r20
	jmp main


power_selection_state:	   
    push r16
	Display_Power_Text
	sbr status, 5 ; setting status to power selection state
    pop r16
    ret

in_power_state:
    push r16
    cpi pattern, '#'
    breq exitPowerState
    cpi pattern, 4    
    brlo p1 ; less than 4
    pop r16
    ret ; invalid input, polling to read next input
p1:
    cpi pattern, 1 
    brsh p2 ; greater than or equal to 1
    pop r16
    ret ; invalid input, polling to read next input
p2:
    mov power,pattern

exitPowerState:
    cbr status,5
    pop r16
    ret


	



digit_process_pattern:	   
    push r16
	push temp
	push ZL
	push ZH
	clr temp
	ldi ZL,low(Buffer)
	ldi ZH,high(Buffer)
	add ZL,index
	adc ZLH,temp
	st Z,pattern
	inc index
	cpi index,4
	brne return3
	clr index
    Transfer_To_Time
return3:
	pop ZH
	pop ZL
	pop temp
    pop r16
	ret
	
clear_entered:
	push temp
	clr temp
	sts Buffer,temp
	sts Buffer+1,temp
	sts Buffer+2,temp
	sts Buffer+3,temp
    sts Time+1,temp
    sts Time.temp
	pop temp
	ret


























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
	ret

//call this function after setting the r24 to the corresponding 
//value of the turntabel you want
Display_Turntable:
	push r16
	push r21
	do_lcd_command 0b00000010 ; cursor home
	rcall move_cursor
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
	ldi r16,92
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
	do_lcd_command 0b00000010;cursor home
	lds XL,Time
	lds XH,Time+1
	rcall IntToA
	lds r16,':'
	do_lcd_data 
	lds XL,Time+2
	lds XH,Time+3
	rcall IntToA
	pop r21
	pop r16
	ret

//set r24 to the 0 for "O" ,1 for "C"
Display_OC:
	push r21
	push r16
	sbr r21,7
	out DDRC,r21

	do_lcd_command 0b11000000;move to second line
    rcall move_cursor
	cpi r24,0
	breq set_to_O
	ldi r16,'C'
	do_lcd_data
	ret
set_to_O:
	ldi r16,'O'
	do_lcd_data 
	pop r16
	pop r21
	ret

//a function of moveing the cursor to the right most position
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
	popr16
	ret	
	
Display_Power_Text:
	push r16
	ldi r16,'R'
	do_lcd_data 
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
hundred:
	cpi XL,100
	ldi r20,0
	cpc XH,r20
	brsh addHundreds
	cpi r21,0
	breq ten
	mov r16,r21
	add r16,r19;+'0'
	do_lcd_data
ten:
	cpi XL,10
	brsh addTens
	mov r16,r22
	cpi r21,0
	breq checkingMe
	rjmp printingMe
checkingMe:
	cpi r22,0
	breq one
printingMe:
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
addHundreds:
	inc r21
	sbiw XH:XL,50
	sbiw XH:XL,50
	rjmp hundred	
addTens:
	inc r22
	subi XL,10
	rjmp ten
addOnes:
	inc r23
	subi XL,1
	rjmp one

//use r24 as paramter passed in this function
//255:full speed;128:half speed;64:25% speed
Motor_Spin:
	push temp
	sts OCR3L,r24
	clr temp
	sts OCR3H,temp
	pop temp
	ret

Back_Light_On:
	push temp
	ldi temp,255
	sts OCR5L,temp
	clr temp
	sts OCR5H,temp
	pop temp
	ret

Back_Light_Off:
	push temp
	ldi temp,0
	sts OCR5L,temp
	clr temp
	sts OCR5H,temp
	pop temp
	ret

Back_Light_Fade:
	push temp
	ldi temp,250
comparing_intensity:
	cpi temp,0
	brsh light
finished:
	clr temp
	sts OCR5H,temp
	pop temp
	ret
light:
	sts OCR5L,temp
	dec temp
	rcall sleep_1ms
	rcall slee[_1ms
	rjmp comparing_intensityl

Display_Buffer:
	push r16
	lds r16,Buffer
	do_lcd_data
	lds r16,Buffer+1
	do_lcd_data
	ldi r16,':'
	do_lcd_data
	lds r16,Buffer+2
	do_lcd_data
	lds r16,Buffer+3
	do_lcd_data
	pop r16
	ret


//Transfer values from Buffer to Time in data space
Transfer_To_Time:
	push r16
	push r17
    push r18
    push r19
    ldi r16,10
    lds r19,Buffer+1
    lds r18,Buffer
    mul r19,r16
    mov r19,r0;
	add r19,r18
    sts Time
   
    lds r19,Buffer+3
    lds r18,Buffer+2
    mul r19,r16
    mov r19,r0;
	add r19,r18
    sts Time+1
    pop r19
    pop r18
    pop r17
    pop r16
    ret
	         
.dseg
Buffer:
	.byte 4 ; holding the four values entered
Time:
	.byte 2 ; format:"xx:xx",minutes:seconds
