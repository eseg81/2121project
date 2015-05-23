.include "m2560def.inc"
.equ LCD_RS = 7
.equ LCD_E = 6
.equ LCD_RW = 5
.equ LCD_BE = 4
.equ LCD_BL = 3;back light
.equ F_CPU = 16000000
.equ DELAY_1MS = F_CPU / 4 / 1000 - 4
.def col = r16 ; stores the current column being scanned
.def row = r17 ; stores the current row
.def cmask = r18 ; column mask used to determine which column to give low signal
.def rmask = r19 ; row mask used to find out if any row has low signal
.def temp = r20
.def temp2 = r22
.def pattern = r21 ; stores the key pressed 
.def status = r23 ; bit 0 set when in entry mode, bit 1 set when in running mode
				  ; bit 2 set when in paused mode, bit 3 set when in finished mode
				  ; bit 4 set when door open (0 when closed), bit 5 set when power level
				  ; is 100%, bit 6 set when power is 50% and bit 7 is set when power is 25%
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
	rjmp continue

symbols_or_0: ; find which symbol pressed, or if 0
	cpi col, 0 ; col 0 is a star
	breq star
	cpi col, 1 ; col 1 is 0
	breq zero
	ldi temp, '#' ; otherwise it is #
	rjmp continue
	
star:
	ldi temp, '*'
	rjmp continue
	
zero:
	ldi temp, 0		 

continue:
	mov pattern,temp
	rjmp act_on_input

act_on_input: ; deals with the key entered on the keypad
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
	breq select_power_level
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
	clr r16;changing portF to input port
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
	do_lcd_data 'D'
	do_lcd_data 'O'
	do_lcd_data 'N'
	do_lcd_data 'E'
	do_lcd_command 0b11000000 ;cursor second line

	do_lcd_data 'R'
	do_lcd_data 'e'
	do_lcd_data 'm'
	do_lcd_data 'o'
	do_lcd_data 'v'
	do_lcd_data 'e'
	do_lcd_data ' '
	do_lcd_data 'f'
	do_lcd_data 'o'
	do_lcd_data 'o'
	do_lcd_data 'd'
	ret

//call this function after setting the r24 to the corresponding 
//value of the turntabel you want
Display_Turntable:
	push r16
	push r21
	do_lcd_command 0b00000010;cursor home
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
	lds r16,Time
	do_lcd_data 
	lds r16,Time+1
	do_lcd_data 
	lds r16,':'
	do_lcd_data 
	lds r16,Time+2
	do_lcd_data 
	lds r16,Time+3
	do_lcd_data 
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
	ret	
	
Display_Power_Text:
	do_lcd_data 'R'
	do_lcd_data 'S'
	do_lcd_data 'e'
	do_lcd_data 't'
	do_lcd_data ' '
	do_lcd_data 'P'
	do_lcd_data 'o '
	do_lcd_data 'w'
	do_lcd_data 'e'
	do_lcd_data 'r'
	do_lcd_data '1'
	do_lcd_data '/'
	do_lcd_data '2'
	do_lcd_data '/'
	do_lcd_data '3'

//use XH:XL as argument(i.e. parameters passed into this function)
IntToA:
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
	rjmp comparing_intensity
.dseg
Time:
	.byte 4
