.include "m2560def.inc"
.equ LCD_RS = 7
.equ LCD_E = 6
.equ LCD_RW = 5
.equ LCD_BE = 4
.equ F_CPU = 16000000
.equ DELAY_1MS = F_CPU / 4 / 1000 - 4
.def temp = r17

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

RSSET:
	ldi temp,low(RAMEND)
	out SPL,temp
	ldi temp,high(RAMEND)
	out SPH,temp

	ser temp
	out DDRF,temp
	out DDRA,temp
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
main:
	ldi r17,1;
	rcall Display_OC
forever:
	rjmp forever


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

//call this function after setting the r17 to the corresponding 
//value of the turntabel you want
Display_Turntable:
	push r16
	push r21
	do_lcd_command 0b00000010;cursor home
	rcall move_cursor
	cpi r17,0;0=-
	breq display_0
	cpi r17,1;1=\
	breq display_1
	cpi r17,2;2=|
	breq display_2
	cpi r17,3;3=/
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

//set r17 to the 0 for "O" ,1 for "C"
Display_OC:
	push r21
	push r16
	sbr r21,7
	out DDRC,r21

	do_lcd_command 0b11000000;move to second line
    rcall move_cursor
	cpi r17,0
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
	
Display_Power_Text
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
.dseg
Time:
	.byte 2
