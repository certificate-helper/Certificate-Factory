import * as React from 'react';
import '../../../css/Button.scss';

interface ButtonProps {
    onClick: () => (void);
    disabled?: boolean;
    small?: boolean;
}
export class Button extends React.Component<ButtonProps, unknown> {
    render(): JSX.Element {
        const className = this.props.small ? 'small' : 'large';

        return (
            <button type="button" className={className} onClick={this.props.onClick} disabled={this.props.disabled}>
                {this.props.children}
            </button>
        );
    }
}
